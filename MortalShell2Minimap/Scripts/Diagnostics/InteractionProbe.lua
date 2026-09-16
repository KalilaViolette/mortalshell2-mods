-- MortalShell2Minimap explicit heavy interaction-discovery diagnostic.
-- Performance intent: completely dormant until Ctrl+Shift+Delete. The first
-- snapshot arms lightweight lifecycle observation so later test stages can be
-- compared. Expensive reflection and targeted FindAllOf calls only run while
-- that hotkey callback is executing. No world UObject wrapper is retained.

local Factory = {}

function Factory.New(ctx)
    local Object = assert(ctx.Object, "InteractionProbe requires Core.Object")
    local log = assert(ctx.Log, "InteractionProbe requires Log")
    local Perf = type(ctx.Perf) == "table" and ctx.Perf
        or { Begin = function() return nil end, End = function() end, Count = function() end }
    local state = assert(ctx.State, "InteractionProbe requires State")
    local Classifier = ctx.LocalClassifier
    local global_runtime = assert(ctx.GlobalRuntime, "InteractionProbe requires GlobalRuntime")
    local instance_generation = assert(ctx.InstanceGeneration, "InteractionProbe requires InstanceGeneration")
    -- v0.18.7: optional. Without a scheduler the probe still emits snapshots; it just
    -- cannot run the wall watch, and says so rather than failing to construct.
    local WorkBudget = type(ctx.WorkBudget) == "table" and ctx.WorkBudget or nil

    -- v0.18.21. Declared HERE, at the top, because OnLoadMapPre -- ~800 lines above the
    -- watch code that owns it -- bumps it, and a local referenced above its declaration
    -- compiles to a nil global that dies only when that line runs (invariant 0c, which
    -- this project has now paid for four times). Arming increments it; a scheduled tick
    -- carries the epoch it was armed with and returns without rescheduling if it no
    -- longer matches, which is what stops watch chains stacking.
    local watch_epoch = 0

    local probe = {
        sequence = 0,
        activated = false,
        hooks = {},
        hook_failures = {},
        quarantined = false,
        world_generation = 0,
        live = {},
        -- v0.18.21: `subjects` holds the actors resolved once at arming, so a tick costs
        -- no scan. Retained wrappers, and invariant 0 applies: every use validates first,
        -- and an invalid one is the observation rather than a reason to look again.
        watch = { active = false, samples = 0, subjects = {}, generation = 0, epoch = 0 },
        counters = {
            hookEvents = 0,
            handlerInitialize = 0,
            handlerEnd = 0,
            handlerRegister = 0,
            handlerUnregister = 0,
            actorBegin = 0,
            actorEnd = 0,
            duplicateUpdates = 0,
            invalidContexts = 0,
            quarantinedEvents = 0,
        },
    }

    local HANDLER = "/Game/Sparta/Core/Common/Interactions/BPC_InteractionHandler.BPC_InteractionHandler_C"
    local INTERACTION = "/Game/Sparta/Core/Interaction/BP_Interaction.BP_Interaction_C"
    local READ_TEXT = "/Game/Sparta/Core/Interaction/BP_InteractionReadText.BP_InteractionReadText_C"
    local PAPER = "/Game/Sparta/Core/Interaction/BP_InteractionReadText_Paper.BP_InteractionReadText_Paper_C"
    local NPC = "/Game/Sparta/Core/AI/BP_NPC.BP_NPC_C"

    -- The base actor and handler are the important hooks. ReadText/Paper BeginPlay
    -- are diagnostic backups so we can prove inheritance/super-call behavior.
    local HOOK_SPECS = {
        { label = "handler.Initialize", path = HANDLER .. ":Initialize", kind = "handler-begin" },
        { label = "handler.CustomInitialize", path = HANDLER .. ":CustomInitialize", kind = "handler-begin" },
        { label = "handler.ReceiveEndPlay", path = HANDLER .. ":ReceiveEndPlay", kind = "handler-end" },
        { label = "handler.RegisterInteractable", path = HANDLER .. ":RegisterInteractable", kind = "handler-register" },
        { label = "handler.UnregisterInteractable", path = HANDLER .. ":UnregisterInteractable", kind = "handler-unregister" },
        { label = "interaction.ReceiveBeginPlay", path = INTERACTION .. ":ReceiveBeginPlay", kind = "actor-begin" },
        { label = "interaction.ReceiveEndPlay", path = INTERACTION .. ":ReceiveEndPlay", kind = "actor-end" },
        { label = "readText.ReceiveBeginPlay", path = READ_TEXT .. ":ReceiveBeginPlay", kind = "actor-begin" },
        { label = "paper.ReceiveBeginPlay", path = PAPER .. ":ReceiveBeginPlay", kind = "actor-begin" },
        { label = "npc.ReceiveBeginPlay", path = NPC .. ":ReceiveBeginPlay", kind = "actor-begin" },
    }

    local function fname(value)
        if value == nil then return nil end
        local ok, result = pcall(function() return value:GetFName():ToString() end)
        return ok and result ~= nil and tostring(result) or nil
    end

    local function class_short(value)
        value = Object.Unwrap(value)
        if not Object.Valid(value) then return nil end
        local class = nil
        local ok = pcall(function() class = Object.Unwrap(value:GetClass()) end)
        if not ok or not Object.Valid(class) then return nil end
        return fname(class)
    end

    local function identity(value)
        value = Object.Unwrap(value)
        if not Object.Valid(value) then return "<nil>" end
        return string.format("%s class=%s addr=%s",
            tostring(Object.ShortName(value) or "<unnamed>"),
            tostring(class_short(value) or "<unknown-class>"),
            tostring(Object.Address(value) or "<no-address>"))
    end

    local function component_owner(component)
        component = Object.Unwrap(component)
        if not Object.Valid(component) then return nil end
        local owner = nil
        pcall(function() owner = Object.Unwrap(component:GetOwner()) end)
        if Object.Valid(owner) then return owner end
        pcall(function() owner = Object.Unwrap(component.Owner) end)
        return Object.Valid(owner) and owner or nil
    end

    local function primitive_location(actor)
        local pos = Object.ActorLocation(actor)
        if pos == nil then return nil end
        return {
            x = tonumber(pos.x) or 0,
            y = tonumber(pos.y) or 0,
            z = tonumber(pos.z) or 0,
        }
    end

    local function record_key(kind, address)
        if address == nil then return nil end
        return tostring(kind) .. ":" .. tostring(address)
    end

    local function capture_actor(source, actor)
        actor = Object.Unwrap(actor)
        if not Object.Valid(actor) then
            probe.counters.invalidContexts = probe.counters.invalidContexts + 1
            return nil
        end
        local address = Object.Address(actor)
        local key = record_key("actor", address)
        if key == nil then return nil end
        local existing = probe.live[key]
        if existing ~= nil then probe.counters.duplicateUpdates = probe.counters.duplicateUpdates + 1 end
        local pos = primitive_location(actor)
        probe.live[key] = {
            kind = "actor",
            address = address,
            class = class_short(actor) or "<unknown-class>",
            name = Object.ShortName(actor) or "<unnamed>",
            x = pos and pos.x or nil,
            y = pos and pos.y or nil,
            z = pos and pos.z or nil,
            source = tostring(source),
            generation = probe.world_generation,
        }
        return probe.live[key]
    end

    local function capture_handler(source, component)
        component = Object.Unwrap(component)
        if not Object.Valid(component) then
            probe.counters.invalidContexts = probe.counters.invalidContexts + 1
            return nil
        end
        local address = Object.Address(component)
        local key = record_key("handler", address)
        if key == nil then return nil end
        local existing = probe.live[key]
        if existing ~= nil then probe.counters.duplicateUpdates = probe.counters.duplicateUpdates + 1 end
        local owner = component_owner(component)
        local pos = primitive_location(owner)
        probe.live[key] = {
            kind = "handler",
            address = address,
            class = class_short(component) or "<unknown-class>",
            name = Object.ShortName(component) or "<unnamed>",
            ownerAddress = Object.Valid(owner) and Object.Address(owner) or nil,
            ownerClass = Object.Valid(owner) and class_short(owner) or nil,
            ownerName = Object.Valid(owner) and Object.ShortName(owner) or nil,
            x = pos and pos.x or nil,
            y = pos and pos.y or nil,
            z = pos and pos.z or nil,
            source = tostring(source),
            generation = probe.world_generation,
        }
        return probe.live[key]
    end

    local function remove_record(kind, object)
        object = Object.Unwrap(object)
        if not Object.Valid(object) then return false end
        local key = record_key(kind, Object.Address(object))
        if key == nil then return false end
        local had = probe.live[key] ~= nil
        probe.live[key] = nil
        return had
    end

    local function note_event(spec, context)
        if global_runtime.generation ~= instance_generation then return end
        probe.counters.hookEvents = probe.counters.hookEvents + 1
        if probe.quarantined and spec.kind ~= "handler-begin"
            and spec.kind ~= "handler-register" and spec.kind ~= "actor-begin" then
            -- PRE has already discarded the old primitive registry. New-world
            -- BeginPlay/Register events are safe to reduce immediately to numbers/
            -- strings, but teardown/unregister callbacks are ignored while the
            -- world is transitioning so we never chase dying wrappers.
            probe.counters.quarantinedEvents = probe.counters.quarantinedEvents + 1
            return
        end

        local row = nil
        if spec.kind == "handler-begin" then
            probe.counters.handlerInitialize = probe.counters.handlerInitialize + 1
            row = capture_handler(spec.label, context)
        elseif spec.kind == "handler-end" then
            probe.counters.handlerEnd = probe.counters.handlerEnd + 1
            remove_record("handler", context)
        elseif spec.kind == "handler-register" then
            probe.counters.handlerRegister = probe.counters.handlerRegister + 1
            row = capture_handler(spec.label, context)
        elseif spec.kind == "handler-unregister" then
            probe.counters.handlerUnregister = probe.counters.handlerUnregister + 1
            remove_record("handler", context)
        elseif spec.kind == "actor-begin" then
            probe.counters.actorBegin = probe.counters.actorBegin + 1
            row = capture_actor(spec.label, context)
        elseif spec.kind == "actor-end" then
            probe.counters.actorEnd = probe.counters.actorEnd + 1
            remove_record("actor", context)
        end

        -- Keep lifecycle observation cheap. Log only a small leading sample and
        -- sparse milestones; Ctrl+Shift+Delete prints the complete heavy snapshot.
        local count = probe.counters.hookEvents
        if count <= 24 or count % 100 == 0 then
            local location = row ~= nil and row.x ~= nil
                and string.format("(%.2f,%.2f,%.2f)", row.x, row.y, row.z or 0)
                or "<none>"
            log(string.format(
                "InteractionProbe lifecycle event=%d kind=%s source=%s object={%s} primitiveClass=%s ownerClass=%s location=%s live=%d",
                count, tostring(spec.kind), tostring(spec.label), identity(context),
                tostring(row and row.class or "<removed>"),
                tostring(row and row.ownerClass or "<none>"), location,
                (function() local n=0 for _ in pairs(probe.live) do n=n+1 end return n end)()))
        end
    end

    local function hook_callback(spec)
        local section = "hook.probe." .. tostring(spec.label)
        return function(context)
            local token = Perf.Begin()
            local ok, err = pcall(note_event, spec, context)
            Perf.End(section, token)
            if not ok then log("InteractionProbe lifecycle callbackError source=" .. tostring(spec.label) .. " error=" .. tostring(err)) end
        end
    end

    function probe.Arm()
        if type(RegisterHook) ~= "function" then
            log("InteractionProbe hook-arm state=RegisterHook-unavailable")
            return 0, #HOOK_SPECS
        end
        local armed = 0
        for _, spec in ipairs(HOOK_SPECS) do
            if probe.hooks[spec.path] == nil then
                local ok, pre_id, post_id = pcall(RegisterHook, spec.path, hook_callback(spec))
                if ok then
                    probe.hooks[spec.path] = { pre = pre_id, post = post_id, label = spec.label }
                    probe.hook_failures[spec.path] = nil
                    log(string.format("InteractionProbe hook-arm label=%s state=armed pre=%s post=%s",
                        spec.label, tostring(pre_id), tostring(post_id)))
                else
                    local previous = probe.hook_failures[spec.path]
                    probe.hook_failures[spec.path] = tostring(pre_id)
                    if previous ~= tostring(pre_id) then
                        log(string.format("InteractionProbe hook-arm label=%s state=pending error=%s",
                            spec.label, tostring(pre_id)))
                    end
                end
            end
            if probe.hooks[spec.path] ~= nil then armed = armed + 1 end
        end
        log(string.format("InteractionProbe hook-arm-summary armed=%d total=%d", armed, #HOOK_SPECS))
        return armed, #HOOK_SPECS
    end

    function probe.OnLoadMapPre()
        if not probe.activated then return end
        probe.quarantined = true
        probe.watch.active = false
        -- v0.18.21: and drop the actors it was holding, in the same breath as the world
        -- that owns them (invariant 0e). Bumping the epoch also orphans any tick still
        -- queued, so nothing walks a wrapper into the next world.
        probe.watch.subjects = {}
        watch_epoch = watch_epoch + 1
        probe.world_generation = probe.world_generation + 1
        probe.live = {}
        log(string.format("InteractionProbe world pre generation=%d registryCleared=true", probe.world_generation))
    end

    function probe.OnWorldReleased(reason)
        if not probe.activated then return end
        probe.quarantined = false
        log(string.format("InteractionProbe world ready generation=%d reason=%s registryPreserved=true live=%d",
            probe.world_generation, tostring(reason or "unknown"),
            (function() local n=0 for _ in pairs(probe.live) do n=n+1 end return n end)()))
        probe.Arm()
    end

    local function read_property(object, name)
        object = Object.Unwrap(object)
        if not Object.Valid(object) then return nil, "object-invalid" end
        local ok, value = pcall(function() return object:GetPropertyValue(name) end)
        if not ok then ok, value = pcall(function() return object[name] end) end
        if not ok then return nil, tostring(value) end
        return value, nil
    end

    local function property_name(property)
        return fname(property)
    end

    local function property_kind(property)
        if property == nil then return "unknown" end
        local class = nil
        local ok = pcall(function() class = property:GetClass() end)
        return ok and class ~= nil and (fname(class) or "unknown") or "unknown"
    end

    -- v0.18.6: the chain walk never walked. Her 094013 run dumped exactly TWO properties
    -- for every wall and for the interaction manager -- PrimaryActorTick and
    -- UberGraphFrame -- and five Blueprint-declared functions. That is one class's own
    -- members, not a chain: `class:GetSuperStruct()` is not callable in this UE4SS build,
    -- the pcall failed, and the loop broke after the first pass. Every reflection dump
    -- this probe has ever produced was that narrow, silently. So try the accessors in
    -- turn and REPORT which one carried the walk, because a walk that quietly does
    -- nothing is worse than no walk at all (invariant 0b: a successful pcall is not
    -- evidence of a result).
    local super_method = nil

    local function super_of(class)
        local candidates = {
            { name = "GetSuperStruct", get = function(c) return c:GetSuperStruct() end },
            { name = "GetSuperClass", get = function(c) return c:GetSuperClass() end },
            { name = "SuperStruct", get = function(c) return c.SuperStruct end },
            { name = "Super", get = function(c) return c.Super end },
        }
        for _, candidate in ipairs(candidates) do
            local super = nil
            local ok = pcall(function() super = Object.Unwrap(candidate.get(class)) end)
            -- A class that returns ITSELF is a dead end, not a parent.
            if ok and Object.Valid(super) and super ~= class then
                super_method = candidate.name
                return super
            end
        end
        return nil
    end

    local function each_class_in_chain(object, callback)
        object = Object.Unwrap(object)
        if not Object.Valid(object) then return 0 end
        local class = nil
        local ok = pcall(function() class = Object.Unwrap(object:GetClass()) end)
        if not ok or not Object.Valid(class) then return 0 end
        local depth, seen = 0, {}
        while Object.Valid(class) and depth < 24 and not seen[class] do
            seen[class] = true
            depth = depth + 1
            callback(class)
            class = super_of(class)
            if class == nil then break end
        end
        return depth
    end

    local function chain_method()
        return tostring(super_method or "none(leaf-class-only)")
    end

    local function collect_properties(object, limit)
        local names, kinds, seen = {}, {}, {}
        limit = math.max(1, math.floor(tonumber(limit) or 240))
        each_class_in_chain(object, function(class)
            pcall(function()
                class:ForEachProperty(function(property)
                    if #names >= limit then return true end
                    local name = property_name(property)
                    if name ~= nil and not seen[name] then
                        seen[name] = true
                        names[#names + 1] = name
                        kinds[name] = property_kind(property)
                    end
                    -- v0.18.15: return NOTHING here. See ENUMERATION_SANITY below --
                    -- returning any value at all stopped the walk after one entry.
                end)
            end)
        end)
        table.sort(names)
        return names, kinds
    end

    local function collect_functions(object, limit)
        local names, seen = {}, {}
        limit = math.max(1, math.floor(tonumber(limit) or 240))
        each_class_in_chain(object, function(class)
            pcall(function()
                class:ForEachFunction(function(fn)
                    if #names >= limit then return true end
                    local name = fname(fn)
                    if name ~= nil and not seen[name] then
                        seen[name] = true
                        names[#names + 1] = name
                    end
                end)
            end)
        end)
        table.sort(names)
        return names
    end

    -- v0.18.9: the function NAME was never the thing RegisterHook needs. v0.18.8 hooked
    -- BP_DestructiblePlaceholderWall_C:GetHitResponse and :ExecuteUbergraph straight off
    -- the autopsy's name list; both came back "no UFunction with the specified name was
    -- found". Two ways that happens, and the name alone distinguishes neither: the real
    -- UFunction is spelled differently (UE writes ExecuteUbergraph_<BPName>), or it is
    -- declared on a PARENT class, so the path has to name that parent -- and now that the
    -- class-chain walk actually works, this list merges the whole chain. Invariant 0f, in
    -- its purest form: a name is not a path. So print the path.
    local function object_path(value)
        value = Object.Unwrap(value)
        if not Object.Valid(value) then return nil end
        for _, accessor in ipairs({ "GetFullName", "GetPathName", "GetFullPath" }) do
            local result = nil
            local ok = pcall(function() result = value[accessor](value) end)
            if ok and type(result) == "string" and #result > 0 then
                -- GetFullName prefixes the type ("Class /Game/..."); the path is the rest.
                return (result:gsub("^%a+%s+", ""))
            end
        end
        return nil
    end

    -- Every function on the chain, each one printed as the exact string RegisterHook
    -- wants: <declaring class path>:<function name>. Paste it into HOOK_SPECS and it
    -- either arms or says why.
    local function emit_hook_paths(label, object, limit)
        limit = math.max(1, math.floor(tonumber(limit) or 320))
        local emitted, depth = 0, 0
        each_class_in_chain(object, function(class)
            depth = depth + 1
            local class_path = object_path(class) or ("<no-path:" .. tostring(fname(class)) .. ">")
            local functions = {}
            pcall(function()
                class:ForEachFunction(function(fn)
                    if #functions >= limit then return true end
                    local name = fname(fn)
                    if name ~= nil then functions[#functions + 1] = name end
                end)
            end)
            table.sort(functions)
            log(string.format(
                "InteractionProbe wall-class label=%s depth=%d class=%s path=%s functions=%d",
                label, depth, tostring(fname(class) or "?"), class_path, #functions))
            for _, name in ipairs(functions) do
                emitted = emitted + 1
                log(string.format("InteractionProbe wall-hookpath label=%s depth=%d %s:%s",
                    label, depth, class_path, name))
            end
        end)
        log(string.format("InteractionProbe wall-hookpaths label=%s classes=%d functions=%d",
            label, depth, emitted))
    end

    local function shallow(value)
        value = Object.Unwrap(value)
        if value == nil then return "nil" end
        local t = type(value)
        if t == "boolean" or t == "number" then return tostring(value) end
        if t == "string" then
            local s = value:gsub("[\r\n\t]", " ")
            if #s > 180 then s = s:sub(1, 177) .. "..." end
            return string.format("%q", s)
        end
        if Object.Valid(value) then return identity(value) end
        local count = nil
        pcall(function() count = select(1, Object.ArrayCount(value)) end)
        if tonumber(count) ~= nil then return "array count=" .. tostring(count) end
        return tostring(t)
    end

    local function emit_container_preview(label, value)
        value = Object.Unwrap(value)
        if value == nil then return false end
        local count = nil
        pcall(function() count = select(1, Object.ArrayCount(value)) end)
        if tonumber(count) ~= nil then
            count = math.max(0, math.floor(tonumber(count)))
            log(string.format("InteractionProbe manager-container label=%s kind=array count=%d", label, count))
            for i = 1, math.min(count, 24) do
                local item = nil
                pcall(function() item = select(1, Object.ArrayAt(value, i)) end)
                log(string.format("InteractionProbe manager-container-item label=%s index=%d value=%s",
                    label, i, shallow(item)))
            end
            return true
        end
        local emitted, total = 0, 0
        local ok = pcall(function()
            value:ForEach(function(first, second)
                total = total + 1
                if emitted < 24 then
                    emitted = emitted + 1
                    log(string.format("InteractionProbe manager-container-item label=%s index=%d first=%s second=%s",
                        label, emitted, shallow(first), shallow(second)))
                end
                return false
            end)
        end)
        if ok and total > 0 then
            log(string.format("InteractionProbe manager-container label=%s kind=ForEach count=%d emitted=%d",
                label, total, emitted))
            return true
        end
        return false
    end

    local function find_manager()
        local manager = nil
        if type(FindFirstOf) == "function" then
            pcall(function() manager = Object.Unwrap(FindFirstOf("CSPlayerInteractionManager")) end)
        end
        local mode = "FindFirstOf"
        local count = nil
        if not Object.Valid(manager) and type(FindAllOf) == "function" then
            local started = os.clock()
            local ok, values = pcall(FindAllOf, "CSPlayerInteractionManager")
            local ms = (os.clock() - started) * 1000.0
            if ok and type(values) == "table" then
                count = #values
                for _, value in ipairs(values) do
                    value = Object.Unwrap(value)
                    if Object.Valid(value) then manager = value break end
                end
            end
            mode = string.format("FindAllOf cpuMs=%.3f count=%s", ms, tostring(count or "n/a"))
        end
        return manager, mode
    end

    local function emit_manager_snapshot()
        local manager, mode = find_manager()
        if not Object.Valid(manager) then
            log("InteractionProbe manager class=CSPlayerInteractionManager state=not-found lookup=" .. tostring(mode))
            return
        end
        log("InteractionProbe manager state=found lookup=" .. tostring(mode) .. " object={" .. identity(manager) .. "}")
        local functions = collect_functions(manager, 320)
        log(string.format("InteractionProbe manager-functions count=%d", #functions))
        for _, name in ipairs(functions) do
            log("InteractionProbe manager-function name=" .. tostring(name))
        end
        local properties, kinds = collect_properties(manager, 320)
        log(string.format("InteractionProbe manager-properties count=%d", #properties))
        for _, name in ipairs(properties) do
            local value, err = read_property(manager, name)
            local kind = tostring(kinds[name] or "unknown")
            if err == nil then
                log(string.format("InteractionProbe manager-property name=%s kind=%s value=%s",
                    tostring(name), kind, shallow(value)))
                local lk = string.lower(kind)
                if string.find(lk, "array", 1, true) ~= nil
                    or string.find(lk, "map", 1, true) ~= nil
                    or string.find(lk, "set", 1, true) ~= nil then
                    emit_container_preview("manager." .. tostring(name), value)
                end
            else
                log(string.format("InteractionProbe manager-property name=%s kind=%s readError=%s",
                    tostring(name), kind, tostring(err)))
            end
        end
    end

    -- v0.18.4 wall autopsy. Her 09:03 run (bundle 090349) proved that breaking a
    -- BP_DestructiblePlaceholderWall_C produces NO signal we can see: rubble.ManualSpawnItem,
    -- rubble.PercentageSpawnItem and rubble.SpartaApplyHit were all armed and all silent,
    -- hookEvents was identical before and after (2164), the actor survived at the same
    -- address, and the wall's state read came back `unknown` at admission. v0.16.0 assumed
    -- this class inherits the base rubble's break functions and the hidden wall's
    -- WallCollision component; neither assumption was ever checked against the object
    -- itself (invariant 0f). So stop guessing: dump every property NAME, KIND and VALUE on
    -- the nearest instance of each wall class, plus its function list. Two Ctrl+Shift+Delete
    -- snapshots either side of a break then name the field that moves, and the fix reads
    -- that field instead of waiting on a call that never comes.
    local WALL_AUTOPSY_CLASSES = {
        { class = "BP_HiddenWall_C", label = "hiddenWall" },
        { class = "BP_HiddenWall_Base_Natural_Rock_C", label = "hiddenWallRock" },
        { class = "BP_HiddenWall_Base_Natural_Rock_CannonBall_C", label = "hiddenWallCannon" },
        { class = "BP_HiddenWall_Spikes_C", label = "hiddenWallSpikes" },
        { class = "BP_DestructiblePlaceholderWall_C", label = "rubbleWall" },
        { class = "BP_DestructiblePlaceholder_C", label = "rubbleBase" },
        -- v0.18.22 (user, 2026-09-15: "one of the issues we had with enemy tracking was
        -- with flying enemies"). Her 130041 log finally says why, and it is invariant 0f
        -- for the fourth time in this project. v0.16.9 added eight movement probes so a
        -- bat -- which plays no footsteps -- would still move its dot:
        --
        --   ai.OnFoleyVelocity  ai.PlayFoleyLoop  ai.UpdateFoleyParams
        --   ai.OnUpdateFoleyParams  ai.OnFootDown  ai.HandleFootDown
        --   ai.OnPreAggro  ai.OnAggro
        --
        -- ALL EIGHT report `state=pending error=... no UFunction with the specified name
        -- was found`, every arm attempt, in every world. They have never armed once. The
        -- names were taken from somewhere and aimed at a class that does not declare them,
        -- so since v0.16.9 a flying enemy's only refresh sources have been PushPlayer and
        -- UpdateFightTarget -- both of which need the bat to be attacking her. That is
        -- exactly the reported symptom, and it is a fix that has never worked.
        --
        -- So the AI classes go in the autopsy, which since v0.18.15 prints every function
        -- as `<declaring class path>:<name>` off a reflection walk that actually walks.
        -- One Ctrl+Shift+Delete next to a bat names the real movement functions instead of
        -- me guessing a fifth time.
        { class = "BP_Batman_C", label = "bat" },
        { class = "BP_StoneCrab_C", label = "crab" },
        { class = "BP_AICharacter_C", label = "aiCharacter" },
        { class = "BP_NPC_C", label = "aiNpc" },
    }

    local function nearest_instance(class_name, player_pos)
        if type(FindAllOf) ~= "function" then return nil, nil, 0 end
        local ok, values = pcall(FindAllOf, class_name)
        if not ok or type(values) ~= "table" then return nil, nil, 0 end
        local best, best_d2, count = nil, math.huge, 0
        for _, raw in ipairs(values) do
            local object = Object.Unwrap(raw)
            if Object.Valid(object) then
                count = count + 1
                local pos = primitive_location(object)
                local d2 = math.huge
                if pos ~= nil and player_pos ~= nil then
                    local dx, dy, dz = pos.x - player_pos.x, pos.y - player_pos.y, pos.z - player_pos.z
                    d2 = dx * dx + dy * dy + dz * dz
                end
                if best == nil or d2 < best_d2 then best, best_d2 = object, d2 end
            end
        end
        return best, best_d2, count
    end

    -- v0.18.6: AActor fields worth reading by NAME, so the autopsy still says something
    -- when reflection tells us nothing. Her 094013 run proved the reflection path can
    -- come back almost empty; a named read needs no class chain at all.
    local WALL_ACTOR_FIELDS = {
        "bHidden", "bActorEnableCollision", "bActorIsBeingDestroyed", "bNetStartup",
        "bCanBeDamaged", "bIsEditorOnlyActor", "bReplicates", "RootComponent",
        "InitialLifeSpan", "CustomTimeDilation",
    }

    -- The component arrays, read by name for the same reason. This is the part that
    -- matters: a wall that breaks without calling a single Blueprint function still has
    -- to change SOMETHING, and on a Chaos destructible that something is a component --
    -- one hidden, one spawned, collision switched off.
    local COMPONENT_ARRAYS = { "BlueprintCreatedComponents", "InstanceComponents" }

    -- One component's readable state, as a compact record. v0.18.7: every field is read
    -- through Object.Valid first. v0.18.6 walked this array calling methods on whatever
    -- came out of it WITHOUT validating -- invariant 0, broken in the very diagnostic
    -- written to uphold it. Her 094840 run happened to die on an unrelated engine fault
    -- (an Oodle shader-decompression LowLevelFatalError on the render thread, 34 of the
    -- 58 crash folders in that bundle, the engine's own message naming the CPU), so the
    -- unguarded walk was never the proven cause -- which is exactly why it gets fixed
    -- now rather than after it proves itself.
    local COMPONENT_LIMIT = 48

    local function component_state(component)
        component = Object.Unwrap(component)
        if not Object.Valid(component) then return nil end
        local record = { name = "unnamed", class = "unknown",
            visible = "n/a", hidden = "n/a", collision = "n/a", mesh = "n/a" }
        pcall(function() record.name = tostring(fname(component) or "unnamed") end)
        pcall(function()
            local class = Object.Unwrap(component:GetClass())
            if Object.Valid(class) then record.class = tostring(fname(class) or "unknown") end
        end)
        pcall(function() record.visible = tostring(component:IsVisible()) end)
        -- v0.18.7: IsCollisionEnabled() answered n/a on every component in her run.
        -- GetCollisionEnabled() returns the enum and is the read that actually works --
        -- and it is the one that matters, because BlockingVolume is what stops you
        -- walking through the wall.
        pcall(function() record.collision = tostring(component:GetCollisionEnabled()) end)
        if record.collision == "n/a" then
            pcall(function() record.collision = tostring(component:IsCollisionEnabled()) end)
        end
        pcall(function() record.hidden = tostring(component.bHiddenInGame == true) end)
        pcall(function()
            local asset = Object.Unwrap(component.StaticMesh)
            if Object.Valid(asset) then record.mesh = tostring(fname(asset) or "n/a") end
        end)
        return record
    end

    local function each_component(actor, callback)
        local total, skipped = 0, 0
        for _, array_name in ipairs(COMPONENT_ARRAYS) do
            local array, err = read_property(actor, array_name)
            if err == nil then
                local values = Object.ArrayCopy(Object.Unwrap(array))
                if type(values) == "table" then
                    for index, raw in ipairs(values) do
                        if total >= COMPONENT_LIMIT then break end
                        local record = component_state(raw)
                        if record == nil then
                            skipped = skipped + 1
                        else
                            total = total + 1
                            callback(array_name, index, record)
                        end
                    end
                end
            end
        end
        return total, skipped
    end

    local function emit_components(label, actor)
        local total, skipped = each_component(actor, function(array_name, index, record)
            log(string.format(
                "InteractionProbe wall-component label=%s array=%s index=%d name=%s class=%s"
                .. " visible=%s hiddenInGame=%s collision=%s mesh=%s",
                label, array_name, index, record.name, record.class,
                record.visible, record.hidden, record.collision, record.mesh))
        end)
        if skipped > 0 then
            log(string.format("InteractionProbe wall-components label=%s skippedInvalid=%d",
                label, skipped))
        end
        return total
    end

    -- v0.18.15 ENUMERATION_SANITY. The user asked whether I was actually certain there is
    -- no hook. I was not, and her own logs prove it: the autopsy reported
    -- `BP_HiddenWall_C functions=1` while this mod had SIX hooks armed on that exact class
    -- (DisableCollision, FadeMaterialOpacity, ProximityOverlap, ShouldReveal,
    -- SolutionTriggered, SpartaApplyHit, all with real hook ids). It also reported
    -- `/Script/Engine.Actor functions=1` and `/Script/CoreUObject.Object functions=1`,
    -- which cannot be true of either.
    --
    -- The cause: every callback ended by returning a value. UE4SS treats ANY return as
    -- "stop", so each walk ended after its first entry. One per class, deduped across the
    -- chain -- which is exactly the 4-5 function lists and the 2-property dumps we have
    -- been reasoning from since v0.18.4. Four versions of "the wall declares nothing" rest
    -- on a list that was never more than one item deep.
    --
    -- So the walk now returns nothing, and every dump states what it found on a class that
    -- is KNOWN to be rich. If Actor comes back with a handful of functions, the enumerator
    -- is broken again and the log says so instead of letting the next person build on it
    -- (invariant 0b: a call that returns without erroring is not evidence of a result).
    local SANITY_CLASS = "/Script/Engine.Actor"
    local SANITY_MINIMUM = 20

    local function emit_enumeration_sanity(object)
        local counted, chain = nil, 0
        each_class_in_chain(object, function(class)
            chain = chain + 1
            if counted ~= nil then return end
            if tostring(object_path(class) or "") ~= SANITY_CLASS then return end
            local n = 0
            pcall(function()
                class:ForEachFunction(function() n = n + 1 end)
            end)
            counted = n
        end)
        if counted == nil then
            log(string.format("InteractionProbe enumeration-sanity chain=%d class=%s state=not-in-chain",
                chain, SANITY_CLASS))
            return
        end
        log(string.format(
            "InteractionProbe enumeration-sanity chain=%d class=%s functions=%d minimum=%d verdict=%s",
            chain, SANITY_CLASS, counted, SANITY_MINIMUM,
            counted >= SANITY_MINIMUM and "trustworthy"
                or "UNDER-REPORTING -- every function and property list in this snapshot is short"))
    end

    -- v0.18.15: the components' OWN classes, and the child actor behind a
    -- ChildActorComponent. `AdditionalProps` is a ChildActorComponent and it is one of the
    -- three things destroyed at the break -- destroying it destroys its CHILD ACTOR, whose
    -- class we have never once looked at. A Blueprint actor almost always has a
    -- ReceiveEndPlay, and that would be the exact moment, for free. The Chaos
    -- GeometryCollectionComponent is worth the same treatment: it is the thing that
    -- actually fractures.
    local function emit_component_classes(label, actor)
        each_component(actor, function(_, _, record)
            -- Only the few that could plausibly carry a break signal; dumping all 25
            -- class chains would be noise.
            local interesting = record.class:find("ChildActor", 1, true)
                or record.class:find("GeometryCollection", 1, true)
                or record.class:find("FieldSystem", 1, true)
                or record.class:find("Timeline", 1, true)
            if not interesting then return end
            log(string.format("InteractionProbe wall-subject label=%s name=%s class=%s",
                label, record.name, record.class))
        end)
        -- The child actors themselves, by name, off the actor's own properties.
        for _, key in ipairs({ "AdditionalProps", "GeometryCollection", "FieldSystem" }) do
            local value = read_property(actor, key)
            local component = Object.Unwrap(value)
            if Object.Valid(component) then
                log(string.format("InteractionProbe wall-subject-path label=%s name=%s path=%s",
                    label, key, tostring(object_path(component) or "<none>")))
                emit_hook_paths(label .. "." .. key, component, 320)
                -- A ChildActorComponent owns an actor; that actor is the thing that dies.
                local child = nil
                pcall(function() child = Object.Unwrap(component:GetChildActor()) end)
                if not Object.Valid(child) then
                    pcall(function() child = Object.Unwrap(component.ChildActor) end)
                end
                if Object.Valid(child) then
                    log(string.format(
                        "InteractionProbe wall-child label=%s component=%s child={%s} path=%s",
                        label, key, identity(child), tostring(object_path(child) or "<none>")))
                    emit_hook_paths(label .. "." .. key .. ".child", child, 320)
                end
            end
        end
    end

    local function emit_wall_autopsy(player_pos)
        local sanity_done = false
        for _, spec in ipairs(WALL_AUTOPSY_CLASSES) do
            local object, d2, count = nearest_instance(spec.class, player_pos)
            if not sanity_done and Object.Valid(object) then
                sanity_done = true
                emit_enumeration_sanity(object)
            end
            if not Object.Valid(object) then
                log(string.format("InteractionProbe wall-autopsy label=%s class=%s instances=%d state=none",
                    spec.label, spec.class, count))
            else
                local distance = (d2 ~= nil and d2 < math.huge) and (math.sqrt(d2) / 100.0) or -1
                log(string.format(
                    "InteractionProbe wall-autopsy label=%s class=%s instances=%d distanceM=%.3f object={%s}",
                    spec.label, spec.class, count, distance, identity(object)))
                local functions = collect_functions(object, 320)
                local properties, kinds = collect_properties(object, 320)
                log(string.format(
                    "InteractionProbe wall-autopsy-reflection label=%s superAccessor=%s functions=%d properties=%d",
                    spec.label, chain_method(), #functions, #properties))
                log(string.format("InteractionProbe wall-autopsy-functions label=%s count=%d list=%s",
                    spec.label, #functions, table.concat(functions, "|")))
                -- v0.18.9: and the same functions again, as hookable paths.
                emit_hook_paths(spec.label, object, 320)
                for _, name in ipairs(properties) do
                    local value, err = read_property(object, name)
                    local kind = tostring(kinds[name] or "unknown")
                    if err == nil then
                        log(string.format("InteractionProbe wall-property label=%s name=%s kind=%s value=%s",
                            spec.label, tostring(name), kind, shallow(value)))
                    else
                        log(string.format("InteractionProbe wall-property label=%s name=%s kind=%s readError=%s",
                            spec.label, tostring(name), kind, tostring(err)))
                    end
                end
                -- Named reads: these run whether or not reflection found anything.
                for _, name in ipairs(WALL_ACTOR_FIELDS) do
                    local value, err = read_property(object, name)
                    if err == nil then
                        log(string.format("InteractionProbe wall-actor-field label=%s name=%s value=%s",
                            spec.label, name, shallow(value)))
                    end
                end
                local components = emit_components(spec.label, object)
                emit_component_classes(spec.label, object)
                log(string.format("InteractionProbe wall-autopsy-end label=%s components=%d",
                    spec.label, components))
            end
        end
    end

    local function player_location()
        local player = Object.Unwrap(state.player)
        if not Object.Valid(player) and type(FindFirstOf) == "function" then
            pcall(function() player = Object.Unwrap(FindFirstOf("BP_PlayerCharacter_C")) end)
        end
        return player, primitive_location(player)
    end

    local function live_count()
        local n = 0
        for _ in pairs(probe.live) do n = n + 1 end
        return n
    end

    local function emit_live_registry()
        local player, player_pos = player_location()
        log(string.format(
            "InteractionProbe registry-summary live=%d hookEvents=%d handlerInitialize=%d handlerEnd=%d handlerRegister=%d handlerUnregister=%d actorBegin=%d actorEnd=%d duplicateUpdates=%d invalidContexts=%d quarantinedEvents=%d generation=%d player={%s}",
            live_count(), probe.counters.hookEvents, probe.counters.handlerInitialize,
            probe.counters.handlerEnd, probe.counters.handlerRegister,
            probe.counters.handlerUnregister, probe.counters.actorBegin, probe.counters.actorEnd,
            probe.counters.duplicateUpdates, probe.counters.invalidContexts,
            probe.counters.quarantinedEvents, probe.world_generation, identity(player)))

        local class_counts = {}
        local rows = {}
        for _, row in pairs(probe.live) do
            local class_label = row.kind == "handler"
                and ("handler-owner:" .. tostring(row.ownerClass or "<none>"))
                or ("actor:" .. tostring(row.class or "<none>"))
            class_counts[class_label] = (class_counts[class_label] or 0) + 1
            local d2 = math.huge
            if player_pos ~= nil and row.x ~= nil then
                local dx = row.x - player_pos.x
                local dy = row.y - player_pos.y
                local dz = (row.z or 0) - (player_pos.z or 0)
                d2 = dx * dx + dy * dy + dz * dz
            end
            rows[#rows + 1] = { row = row, d2 = d2 }
        end
        local classes = {}
        for name, count in pairs(class_counts) do classes[#classes + 1] = { name = name, count = count } end
        table.sort(classes, function(a,b) if a.count ~= b.count then return a.count > b.count end return a.name < b.name end)
        for i = 1, math.min(#classes, 60) do
            log(string.format("InteractionProbe registry-class rank=%d count=%d class=%s", i, classes[i].count, classes[i].name))
        end
        table.sort(rows, function(a,b) return a.d2 < b.d2 end)
        for i = 1, math.min(#rows, 40) do
            local row = rows[i].row
            local distance = rows[i].d2 < math.huge and (math.sqrt(rows[i].d2) / 100.0) or -1
            log(string.format(
                "InteractionProbe registry-near rank=%d distanceM=%.3f kind=%s class=%s name=%s addr=%s ownerClass=%s ownerName=%s ownerAddr=%s source=%s location=(%s,%s,%s)",
                i, distance, tostring(row.kind), tostring(row.class), tostring(row.name),
                tostring(row.address), tostring(row.ownerClass or "<none>"),
                tostring(row.ownerName or "<none>"), tostring(row.ownerAddress or "<none>"),
                tostring(row.source), tostring(row.x or "nil"), tostring(row.y or "nil"), tostring(row.z or "nil")))
        end
    end

    -- Which component's collision each census prints (the read Local/Discovery makes).
    local CENSUS_COLLISION = {
        hiddenWall = "WallCollision", rubbleWall = "WallCollision",
        flowerChest = "HitDetectionCollision", attackFlower = "Capsule",
    }

    local function targeted_census(class_name, label, player_pos, limit)
        if type(FindAllOf) ~= "function" then return end
        local started = os.clock()
        local ok, values = pcall(FindAllOf, class_name)
        local ms = (os.clock() - started) * 1000.0
        if not ok or type(values) ~= "table" then
            log(string.format("InteractionProbe census label=%s class=%s state=failed cpuMs=%.3f error=%s",
                label, class_name, ms, tostring(values)))
            return
        end
        local rows, valid, located = {}, 0, 0
        local production_records = type(ctx.LocalDiscovery) == "table"
            and type(ctx.LocalDiscovery.Records) == "function"
            and ctx.LocalDiscovery.Records() or {}
        for _, raw in ipairs(values) do
            local object = Object.Unwrap(raw)
            if Object.Valid(object) then
                valid = valid + 1
                local actor = object
                if string.find(string.lower(class_name), "interactionhandler", 1, true) ~= nil then
                    actor = component_owner(object)
                end
                local pos = primitive_location(actor)
                if pos ~= nil then
                    located = located + 1
                    local d2 = math.huge
                    if player_pos ~= nil then
                        local dx,dy,dz = pos.x-player_pos.x,pos.y-player_pos.y,(pos.z or 0)-(player_pos.z or 0)
                        d2 = dx*dx+dy*dy+dz*dz
                    end
                    local actor_class = class_short(actor) or "<unknown-class>"
                    local actor_address = Object.Valid(actor) and Object.Address(actor) or nil
                    local policy_text = "classifier-unavailable"
                    if type(Classifier) == "table" and type(Classifier.Classify) == "function" then
                        local policy, reject_reason = Classifier.Classify(actor_class)
                        policy_text = policy ~= nil
                            and ("admit:" .. tostring(policy.key or "unknown"))
                            or ("reject:" .. tostring(reject_reason or "unclassified"))
                    end
                    rows[#rows+1] = {
                        object=object, actor=actor, pos=pos, d2=d2,
                        actor_class=actor_class,
                        production_record=actor_address ~= nil
                            and production_records[actor_address] ~= nil,
                        policy=policy_text,
                    }
                end
            end
        end
        table.sort(rows, function(a,b) return a.d2 < b.d2 end)
        log(string.format("InteractionProbe census label=%s class=%s candidates=%d valid=%d located=%d cpuMs=%.3f diagnosticTargetedPass=1",
            label, class_name, #values, valid, located, ms))
        for i=1,math.min(#rows, math.max(1, math.floor(tonumber(limit) or 12))) do
            local r=rows[i]
            local dist=r.d2 < math.huge and math.sqrt(r.d2)/100.0 or -1
            -- v0.10.11 state evidence (heavy path only, top rows only): which game
            -- flags change when an object stops/starts being interactable or visible.
            local hidden, locked, active = "n/a", "n/a", "n/a"
            pcall(function() hidden = tostring(r.actor.bHidden) end)
            pcall(function() locked = tostring(r.object.InteractionLocked) end)
            pcall(function() active = tostring(r.object:IsActive()) end)
            local shown = "n/a"
            if r.production_record == true then
                local addr = Object.Address(r.actor)
                local rec = addr ~= nil and production_records[addr] or nil
                if type(rec) == "table" then shown = tostring(rec.suppressed ~= true) end
            end
            -- v0.16.0: the wall censuses also print what the WallCollision mesh says, which
            -- is the read Local/Discovery uses to skip a wall already opened at load (an
            -- open wall has no record). The heavy path is where that read gets its
            -- evidence (invariant 0b): a wall with a record must show collision=true.
            -- v0.16.6: the plant censuses read the same component Local/Discovery reads
            -- (HitDetectionCollision on the flower chest, Capsule on the attack flower)
            -- and the two saved counters beside it, so a spent plant with a record, or a
            -- live one without, is visible in one line.
            local collision = "n/a"
            local collision_component = CENSUS_COLLISION[label]
            if collision_component ~= nil then
                pcall(function()
                    local mesh = Object.Unwrap(r.actor[collision_component])
                    -- v0.18.4: name the component that was missing. "no-mesh" read as
                    -- "this actor has no mesh" and hid the real finding, which was that
                    -- BP_DestructiblePlaceholderWall_C has no WallCollision at all -- a
                    -- component name borrowed from the hidden-wall family on the strength
                    -- of the word "Wall" and never checked.
                    if Object.Valid(mesh) then collision = tostring(mesh:IsCollisionEnabled())
                    else collision = "no-" .. tostring(collision_component) end
                end)
            end
            local plant = ""
            if label == "flowerChest" or label == "attackFlower" then
                local extracted, hits, required = "n/a", "n/a", "n/a"
                pcall(function() extracted = tostring(r.actor.RewardExtracted) end)
                pcall(function() hits = tostring(r.actor.HitsReceived) end)
                pcall(function() required = tostring(r.actor.RequiredHits) end)
                plant = string.format(" rewardExtracted=%s hits=%s/%s", extracted, hits, required)
            end
            log(string.format("InteractionProbe census-near label=%s rank=%d distanceM=%.3f object={%s} owner={%s} policy=%s productionRecord=%s shown=%s collision=%s%s hidden=%s locked=%s active=%s",
                label, i, dist, identity(r.object), identity(r.actor),
                tostring(r.policy), tostring(r.production_record == true), shown, collision, plant, hidden, locked, active))
        end
    end

    -- v0.18.7 wall watch. Two runs have now been lost to timing rather than to the bug:
    -- the 094013 pair was nine seconds apart with the player at distanceM=1.906 in both
    -- and every one of the twenty nearest records identical, so the break fell outside
    -- the window. Asking someone to press a key at the right instant, twice, either side
    -- of a two-second animation is a bad instrument. So one Ctrl+Shift+Delete now ARMS a
    -- bounded watch: the nearest wall of each class that actually has instances is
    -- sampled once a second for ninety seconds, and a line is written ONLY when its
    -- signature changes. Walk up, press once, break the wall, done -- and the log carries
    -- the transition with a timestamp. It stops on its own, on a world change, and on a
    -- second snapshot, so it can never become a background cost.
    local WATCH_SAMPLES = 90
    local WATCH_INTERVAL_MS = 1000
    -- v0.18.21, and this one is measured, not guessed. Her 124344 run:
    --
    --   probe.wall-watch  n=20 ms=1307 avg=65.35 max=90.0 lifeMax=523.0
    --
    -- 65 ms EVERY SECOND, which is four dropped frames a second; the minimap's busyPct
    -- tracked it exactly (2.7% with the watch idle, 33.9% with it running) and the tick
    -- rate fell from 48.8/s to 38.7/s. She felt it and said so. Two causes, both mine:
    --
    --   * every tick called nearest_instance() per class, and nearest_instance is a
    --     FindAllOf. Four classes, once a second, at ~10.4 ms each = ~40 ms of the 65 --
    --     a diagnostic doing four global scans a second while the whole mod exists to
    --     avoid doing one. The subject is now resolved ONCE at arming and the wrapper
    --     held (validated on every use, invariant 0); losing it is the "actor gone"
    --     answer we are watching for, not a reason to scan again.
    --   * it watched every wall class with an instance ANYWHERE. Her log shows three
    --     subjects at distanceM=699.061 while she stood at the one 9.3 m away. Watching
    --     a wall 700 m away cannot observe anything and cost three quarters of the time.
    --
    -- So: subjects are range-gated at arming and dropped when the player leaves.
    local WATCH_RANGE_SQ = 5000.0 * 5000.0 -- 50 m
    -- Arming REPLACES a running watch. It used to allocate a fresh probe.watch while the
    -- old chain's scheduled tick was still queued; that tick then saw active=true, ticked
    -- the new state and rescheduled itself, so every press added a concurrent chain. She
    -- pressed Ctrl+Shift+Delete 24 times and the watch ran at 2.0/s instead of 1 Hz.
    -- The epoch is the fix: a tick that is not the current one returns and does not
    -- reschedule. (The same shape as invariant 0's generation guards elsewhere.)
    -- `watch_epoch` itself is declared at the TOP of this module -- see invariant 0c.

    local function component_signature(actor)
        local parts = {}
        each_component(actor, function(_, _, record)
            parts[#parts + 1] = string.format("%s/%s:v=%s,h=%s,c=%s,m=%s",
                record.name, record.class, record.visible, record.hidden,
                record.collision, record.mesh)
        end)
        table.sort(parts)
        local actor_parts = {}
        for _, name in ipairs(WALL_ACTOR_FIELDS) do
            local value, err = read_property(actor, name)
            if err == nil then
                actor_parts[#actor_parts + 1] = name .. "=" .. shallow(value)
            end
        end
        return table.concat(actor_parts, ",") .. " || " .. table.concat(parts, " ")
    end

    -- The subject's distance from the player, from the wrapper we are already holding.
    -- No scan: this is arithmetic on one actor's location.
    local function watch_distance_sq(object, player_pos)
        if player_pos == nil then return nil end
        local pos = primitive_location(object)
        if pos == nil then return nil end
        local dx, dy, dz = pos.x - player_pos.x, pos.y - player_pos.y, pos.z - player_pos.z
        return dx * dx + dy * dy + dz * dz
    end

    local function watch_tick(epoch)
        -- A tick from a superseded arming does nothing and, crucially, does not
        -- reschedule -- that is what stops the chains stacking.
        if epoch ~= watch_epoch then return end
        if not probe.watch.active then return end
        if probe.quarantined or probe.watch.generation ~= probe.world_generation then
            log(string.format("InteractionProbe wall-watch state=stopped reason=world-changed samples=%d",
                probe.watch.samples))
            probe.watch.active = false
            return
        end
        probe.watch.samples = probe.watch.samples + 1
        local _, player_pos = player_location()
        local token = Perf.Begin()
        local watching = 0
        for _, subject in ipairs(probe.watch.subjects) do
            if not subject.done then
                local object = Object.Unwrap(subject.actor)
                if not Object.Valid(object) then
                    -- The wrapper going invalid IS the observation. Do not scan again to
                    -- look for a replacement: the subject we armed on is what we watch.
                    subject.done = true
                    log(string.format(
                        "InteractionProbe wall-watch label=%s class=%s sample=%d CHANGE=actor-gone",
                        subject.label, subject.class, probe.watch.samples))
                else
                    local d2 = watch_distance_sq(object, player_pos)
                    if d2 ~= nil and d2 > WATCH_RANGE_SQ then
                        subject.done = true
                        log(string.format(
                            "InteractionProbe wall-watch label=%s class=%s sample=%d"
                            .. " state=dropped reason=out-of-range distanceM=%.3f",
                            subject.label, subject.class, probe.watch.samples,
                            math.sqrt(d2) / 100.0))
                    else
                        watching = watching + 1
                        local signature = component_signature(object)
                        if subject.last ~= signature then
                            local previous = subject.last
                            subject.last = signature
                            local distance = d2 ~= nil and (math.sqrt(d2) / 100.0) or -1
                            log(string.format(
                                "InteractionProbe wall-watch label=%s class=%s sample=%d distanceM=%.3f %s",
                                subject.label, subject.class, probe.watch.samples, distance,
                                previous == nil and "BASELINE" or "CHANGE"))
                            if previous ~= nil then
                                log("InteractionProbe wall-watch-was label=" .. subject.label .. " " .. tostring(previous))
                            end
                            log("InteractionProbe wall-watch-now label=" .. subject.label .. " " .. signature)
                        end
                    end
                end
            end
        end
        Perf.End("probe.wall-watch", token)
        -- Every subject retired: nothing left to observe, so stop rather than tick out
        -- the remaining samples doing nothing.
        if watching == 0 then
            log(string.format("InteractionProbe wall-watch state=finished samples=%d"
                .. " reason=no-subjects-left", probe.watch.samples))
            probe.watch.active = false
            return
        end
        if probe.watch.samples >= WATCH_SAMPLES then
            log(string.format("InteractionProbe wall-watch state=finished samples=%d"
                .. " -- press Ctrl+Shift+Delete again to watch for another %d seconds",
                probe.watch.samples, WATCH_SAMPLES))
            probe.watch.active = false
            return
        end
        if type(WorkBudget) == "table" and type(WorkBudget.Schedule) == "function" then
            WorkBudget.Schedule(WATCH_INTERVAL_MS, function() watch_tick(epoch) end, "probe.wall-watch")
        else
            probe.watch.active = false
        end
    end

    local function arm_wall_watch(player_pos)
        if type(WorkBudget) ~= "table" or type(WorkBudget.Schedule) ~= "function" then
            log("InteractionProbe wall-watch state=unavailable reason=no-scheduler")
            return
        end
        -- Resolved ONCE, here. This is the only place the watch scans, and it is the
        -- same scan EmitSnapshot is already doing around it.
        local subjects, skipped = {}, 0
        for _, spec in ipairs(WALL_AUTOPSY_CLASSES) do
            local object, d2 = nearest_instance(spec.class, player_pos)
            if Object.Valid(object) then
                if d2 ~= nil and d2 > WATCH_RANGE_SQ then
                    skipped = skipped + 1
                else
                    subjects[#subjects + 1] = {
                        label = spec.label, class = spec.class, actor = object,
                        last = nil, done = false,
                    }
                end
            end
        end
        if #subjects == 0 then
            log(string.format("InteractionProbe wall-watch state=idle"
                .. " reason=no-wall-within-%dm outOfRange=%d",
                math.floor(math.sqrt(WATCH_RANGE_SQ) / 100.0), skipped))
            return
        end
        watch_epoch = watch_epoch + 1
        local epoch = watch_epoch
        probe.watch = {
            active = true, samples = 0, subjects = subjects,
            generation = probe.world_generation, epoch = epoch,
        }
        local names = {}
        for _, subject in ipairs(subjects) do names[#names + 1] = subject.label end
        log(string.format(
            "InteractionProbe wall-watch state=armed epoch=%d classes=%s outOfRange=%d"
            .. " samples=%d intervalMs=%d rangeM=%d"
            .. " -- break the wall now; a line is written only when something changes",
            epoch, table.concat(names, "|"), skipped, WATCH_SAMPLES, WATCH_INTERVAL_MS,
            math.floor(math.sqrt(WATCH_RANGE_SQ) / 100.0)))
        WorkBudget.Schedule(WATCH_INTERVAL_MS, function() watch_tick(epoch) end, "probe.wall-watch")
    end

    function probe.EmitSnapshot(reason)
        probe.activated = true
        probe.sequence = probe.sequence + 1
        reason = tostring(reason or "manual")
        local started = os.clock()
        log(string.format(
            "InteractionProbe BEGIN snapshot=%d reason=%s mode=explicit-heavy-event-registry+manager-reflection+targeted-censuses recurringScan=0 productionGlobalScan=0 broadActorScan=0 broadComponentScan=0",
            probe.sequence, reason))
        probe.Arm()
        local _, player_pos = player_location()
        emit_live_registry()
        emit_manager_snapshot()
        -- Targeted validation only: these are known interaction classes, not broad
        -- Actor/ActorComponent enumeration. They run only on Ctrl+Shift+Delete.
        targeted_census("BPC_InteractionHandler_C", "handler", player_pos, 40)
        targeted_census("BPC_InteractionHandler_Hold_C", "holdHandler", player_pos, 24)
        targeted_census("BP_Interaction_C", "interactionActor", player_pos, 24)
        targeted_census("BP_InteractionReadText_C", "readText", player_pos, 24)
        targeted_census("BP_InteractionReadText_Paper_C", "paper", player_pos, 24)
        targeted_census("BP_Interactable_Shell_Locked_C", "lockedShell", player_pos, 24)
        -- v0.16.0 hidden walls: the two families, with their collision state.
        targeted_census("BP_HiddenWall_C", "hiddenWall", player_pos, 24)
        targeted_census("BP_DestructiblePlaceholderWall_C", "rubbleWall", player_pos, 24)
        -- v0.16.6 plants (spent state) and the teleport sack.
        targeted_census("BP_FlowerChest_C", "flowerChest", player_pos, 12)
        targeted_census("BP_AttackFlower_C", "attackFlower", player_pos, 12)
        targeted_census("BP_BagTeleport_C", "bagTeleport", player_pos, 6)
        -- v0.18.4: the nearest wall of each family, dumped field by field. This is what
        -- says WHAT changes when a wall breaks, since nothing we hook fires.
        emit_wall_autopsy(player_pos)
        -- v0.18.7: and then watch them, so the transition does not depend on anyone
        -- pressing a key at the right instant.
        arm_wall_watch(player_pos)
        log(string.format("InteractionProbe END snapshot=%d reason=%s cpuMs=%.3f",
            probe.sequence, reason, (os.clock() - started) * 1000.0))
        return true
    end

    function probe.IsActive()
        return probe.activated == true
    end

    function probe.ArmedCount()
        local n = 0
        for _, spec in ipairs(HOOK_SPECS) do if probe.hooks[spec.path] ~= nil then n = n + 1 end end
        return n, #HOOK_SPECS
    end

    return probe
end

return Factory
