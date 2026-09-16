-- Event-driven local interactable discovery.
-- Production rule: no recurring FindAllOf/UObject/world scan. Mortal Shell II's
-- own interaction lifecycle is the discovery source.
--
-- v0.10.10 safety rule: this module retains NO UObject references at all. Every
-- record is Lua primitives captured inside a game callback while the object is
-- alive. v0.10.6-v0.10.9 kept up to 32 NPC actor refs and re-read them every
-- 250 ms; five v0.10.9 access violations (minidumps: engine-tick -> Lua ->
-- UE4SS reflection on garbage pointers, same UE4SS+0x36562e site as the
-- historical 0x40 crashes) matched reading actors the game had already freed.
-- NPC position refresh was also nearly useless: 2 moves in ~10,000 reads.
-- Removal comes only from game lifecycle events (EndPlay, unregister, chest
-- opened, pickup collected), which are processed even during LoadMap quarantine.

local Factory = {}

function Factory.New(ctx)
    local Object = assert(ctx.Object, "Local.Discovery requires Core.Object")
    local Config = assert(ctx.Config, "Local.Discovery requires Config")
    local Classifier = assert(ctx.LocalClassifier, "Local.Discovery requires Local.Classifier")
    local WorkBudget = assert(ctx.WorkBudget, "Local.Discovery requires Runtime.WorkBudget")
    local state = assert(ctx.State, "Local.Discovery requires State")
    local global_runtime = assert(ctx.GlobalRuntime, "Local.Discovery requires GlobalRuntime")
    local instance_generation = assert(ctx.InstanceGeneration, "Local.Discovery requires InstanceGeneration")
    local log = assert(ctx.Log, "Local.Discovery requires Log")
    local Perf = type(ctx.Perf) == "table" and ctx.Perf
        or { Begin = function() return nil end, End = function() end, Count = function() end }
    -- v0.11.7: the hot-hook governor's whole behaviour is "how many events in one
    -- second", which is untestable against a real clock without sleeping for three of
    -- them. Only the governor uses this; every other throttle in the file still reads
    -- os.clock() directly, so nothing already covered changes shape.
    local governor_clock = type(ctx.Clock) == "function" and ctx.Clock or os.clock

    local HANDLER = "/Game/Sparta/Core/Common/Interactions/BPC_InteractionHandler.BPC_InteractionHandler_C"
    local INTERACTION = "/Game/Sparta/Core/Interaction/BP_Interaction.BP_Interaction_C"
    local NPC = "/Game/Sparta/Core/AI/BP_NPC.BP_NPC_C"
    local AI_CHARACTER = "/Game/Sparta/Core/AI/BP_AICharacter.BP_AICharacter_C"
    -- v0.18.23: the AI branch's native parent, one class above BP_AICharacter_C. It carries
    -- OnPreAggro / OnAggro / OnDeaggro / OnDeath / IsSpawnFinished / BeginPlay /
    -- SpawnFromSpawnerFinished and nothing else -- seven functions. It is a /Script/ path
    -- but NOT a universal base: BP_PlayerCharacter_C does not inherit it, so a hook here
    -- fires for AI only. (SpartaCharacter, one further up, IS shared with the player --
    -- see the note beside the foley specs.)
    local SPARTA_AI_CHARACTER = "/Script/Sparta.SpartaAICharacter"
    -- v0.18.24: one class further up, and this one the PLAYER inherits too. Everything
    -- hooked here fires for her own character as well as every AI in the level, which is
    -- why the six specs below are armed as a MEASUREMENT rather than assumed safe --
    -- user's call, 2026-09-15, "arm them, measure, then decide". note_enemy drops the
    -- player on an address compare before it reads anything (enemySelfSkipped counts it),
    -- the v0.11.7 governor retires any label that turns out per-frame, and the refresh
    -- floor caps a survivor at 1/60 s. None of that makes the rate KNOWN, which is the
    -- point of the run.
    local SPARTA_CHARACTER = "/Script/Sparta.SpartaCharacter"
    local BLACKSMITH = "/Game/Sparta/Dialogue/NPCs/BP_Blacksmith.BP_Blacksmith_C"
    local GENESSA_TRAINING = "/Game/Sparta/Dialogue/NPCs/BP_NPC_Genessa_Training.BP_NPC_Genessa_Training_C"
    local CHEST_BP = "/Game/Sparta/Core/Common/Interactions/Blueprints/"
    local CHEST = CHEST_BP .. "BP_Interactable_Chest.BP_Interactable_Chest_C"
    local CHEST_GENERAL = CHEST_BP .. "BP_Interactable_Chest_General.BP_Interactable_Chest_General_C"
    local CHEST_SKIN = CHEST_BP .. "BP_Interactable_Chest_Skin.BP_Interactable_Chest_Skin_C"
    local CHEST_SEAL = CHEST_BP .. "BP_Interactable_Chest_Seal.BP_Interactable_Chest_Seal_C"
    local PICKUPS = "/Game/Sparta/Items/Pickups/"
    local PICKUP_BASE = PICKUPS .. "BP_PickupBase.BP_PickupBase_C"
    local PICKUP_CRAFTING = PICKUPS .. "BP_CraftingItemPickup.BP_CraftingItemPickup_C"
    local PICKUP_CURRENCY = PICKUPS .. "BP_CurrencyBag_Pickup.BP_CurrencyBag_Pickup_C"
    local PICKUP_ARTIFACT = PICKUPS .. "BP_Pickup_Artifact.BP_Pickup_Artifact_C"
    local LOCKON_ENV = "/Game/Sparta/Core/Components/LockOn/BPC_LockOnTarget_EnvShooting."
        .. "BPC_LockOnTarget_EnvShooting_C"
    local BEAR_TRAP = "/Game/Sparta/Core/Interaction/BP_BearTrap.BP_BearTrap_C"
    -- v0.14.4: the breakable env-shooting family. BP_ExplosiveBarrel_C is the one the
    -- user actually meets -- the "pots" in the Gates dungeons. v0.16.7 dropped the base
    -- class (BP_EnvShootingObjectBase_C) hooks: its BreakEnvObject / DeleteEnvObject /
    -- HideEnvObject never fired in play (see the Explode entry below).
    local EXPLOSIVE_BARREL =
        "/Game/Sparta/Blueprints/DungeonScripts/BP_ExplosiveBarrel.BP_ExplosiveBarrel_C"
    -- v0.18.1 (user, 2026-09-14: "decorative things that show up under plants but
    -- nothing happens when you hit them, i can actually shoot through them"). Her
    -- 15:24 snapshot in the Central Sewers: six BP_EnvShootingObject_Torch_C records,
    -- Loot, shown, hidden=false, all admitted by the lock-on component's BeginPlay
    -- (v0.11.2) and never retired. The torch class is level-specific and not in the
    -- dump; its base is, with the state the game keeps on every env-shooting object:
    -- GotActivated (the one-shot has fired), IsReady, CanPlayerShootIt and
    -- CanPlayerTargetIt (designer flags), SaveWorldState + UniqueID (the activation is
    -- saved and restored: the ubergraph reads ReadMyBoolPlayerSave), and the functions
    -- that change it: OnWorldStateLoaded (the restore), GotESOactivated (the setter),
    -- Activate / ActivationFinished, InvalidateCollision and Invalidate (a fired torch
    -- keeps its mesh and loses its collision -- "shoot through them"). So a torch's
    -- state is READ at admission, like the plants (v0.16.6), and the base-class
    -- functions that spend one are hooked. Neither BP_BearTrap_C nor
    -- BP_ExplosiveBarrel_C overrides any of the five hooked below (the dump lists
    -- their overrides: Activate, SpartaApplyHit, BreakEnvObject, TriggerEnvObject --
    -- which is exactly why the v0.14.4 base-class hooks on those never fired), so
    -- these fire for the whole family. Post-hooks: the flag is read after the game
    -- wrote it.
    local ENV_OBJECT_BASE =
        "/Game/Sparta/Items/EnvShooting/BP_EnvShootingObjectBase.BP_EnvShootingObjectBase_C"
    -- v0.16.0: hidden and breakable walls (user decision 2026-09-13: show unopened walls
    -- in range). Neither family is an interactable -- her two wall snapshots that day
    -- had the nearest handler 62 m away -- so nothing above could ever see one. From
    -- the 2026-09-12 object dump:
    --   BP_HiddenWall_C: an illusory wall. SpartaApplyHit -> ShouldReveal ->
    --   FadeMaterialOpacity + DisableCollision, a ProximityTrigger overlap, a saved bool.
    --   Only the Natural_Rock and CannonBall variants override ReceiveBeginPlay; the
    --   base and Spikes do not, which is why the seed and the construction notify below
    --   exist at all.
    --   BP_DestructiblePlaceholder_C: Chaos rubble (Wall and Cart variants define
    --   nothing of their own). SpartaApplyHit per hit; Manual/PercentageSpawnItem when
    --   it breaks and drops something.
    -- DisableCollision is the open signal: once per reveal, and the save path calls it
    -- at load for walls already opened. FadeMaterialOpacity is a timeline update and is
    -- counted only (a hot-hook candidate; the governor would retire it harmlessly).
    local WALL_BP = "/Game/Sparta/Core/Common/Interactions/Blueprints/"
    local HIDDEN_WALL = WALL_BP .. "BP_HiddenWall.BP_HiddenWall_C"
    local HIDDEN_WALL_ROCK = WALL_BP
        .. "BP_HiddenWall_Base_Natural_Rock.BP_HiddenWall_Base_Natural_Rock_C"
    local HIDDEN_WALL_CANNON = WALL_BP
        .. "BP_HiddenWall_Base_Natural_Rock_CannonBall.BP_HiddenWall_Base_Natural_Rock_CannonBall_C"
    local RUBBLE_BASE = "/Game/Sparta/Blueprints/BP_DestructiblePlaceholder.BP_DestructiblePlaceholder_C"
    local RUBBLE_WALL = "/Game/Sparta/Blueprints/BP_DestructiblePlaceholderWall.BP_DestructiblePlaceholderWall_C"
    -- v0.18.10: the rubble wall's own parents. BP_VFX_Breakable_C is the game's breakable
    -- family and BP_VFX_Physical_C the physical base under it; the wall itself declares
    -- nothing, so every function it answers to comes from these two. Kept as documentation
    -- of where a future breakable question starts -- v0.18.19 proved neither class runs any
    -- Blueprint when a wall actually breaks, so nothing is hooked on them.
    local HIDDEN_WALL_PROXIMITY = HIDDEN_WALL
        .. ":BndEvt__BP_HiddenWall_ProximityTrigger_K2Node_ComponentBoundEvent_0_ComponentBeginOverlapSignature__DelegateSignature"
    -- v0.16.4 (user, 2026-09-13: "these I have to hit 3 times to get a crafting item").
    -- Three snapshots beside one -- before, after the drop, after the pickup -- showed
    -- nothing we hook within 7 m of it and no hit counted anywhere; the dropped
    -- BP_CraftingItemPickup_C was tracked and retired correctly. The object dump names
    -- it: BP_FlowerChest_C (Environments/ItemPool/Meta, beside BP_AttackFlower): its own
    -- ReceiveBeginPlay, SpartaApplyHit, a HitReaction timeline, a DropItem timeline,
    -- OnItemPickedUp, SaveItemCollected, DisableTargeting, a SpartaSave bound event. A
    -- plant you beat for a crafting item, persisted once collected.
    local FLOWER_CHEST = "/Game/Sparta/Environments/ItemPool/Meta/BP_FlowerChest.BP_FlowerChest_C"
    -- v0.16.6 (user, 2026-09-13: "inactive plants are still drawn on the map ... It's not
    -- hittable either, no collision"). Her 19:35 snapshot: a BP_FlowerChest_C 2.2 m away,
    -- seeded at world-ready with hittableSkipped=0 -- no spent signal had reached us,
    -- because the first world's plants begin play before the hooks exist (v0.16.5). So a
    -- plant's state is now READ, not only awaited. Both plant classes carry the same
    -- three fields in the dump: RewardExtracted (bool), HitsReceived and RequiredHits
    -- (int), and a hit collision the game turns off when spent -- HitDetectionCollision
    -- on the flower chest, Capsule on BP_AttackFlower_C (the second plant she meant:
    -- CanBeTargeted, DisableFlower, ShrinkFlower, SpawnHitReward/SpawnFinalReward per
    -- hit and at the end, InitRegrow/RestartFlower/ForceRegrow, a SpartaSave bool).
    -- The attack flower was already admitted by the lock-on component's BeginPlay
    -- (v0.11.2) and never retired; now it is seeded and read like the chest.
    local ATTACK_FLOWER = "/Game/Sparta/Environments/ItemPool/Meta/BP_AttackFlower.BP_AttackFlower_C"
    -- v0.16.6: BP_BagTeleport_C (Interactions/Blueprints) -- the sack on the ledge, "E:
    -- TOUCH", her 19:36 snapshot at 1.2 m: an ordinary BPC_InteractionHandler owner
    -- that the classifier had parked as a map duplicate "until seen". TeleportToPrison,
    -- Deactivate, OnInteract, a SpartaSave whose runtime datum is a crafting-pickup
    -- save object -- a one-way trip, used once. Admitted as Other; Deactivate retires.
    local BAG_TELEPORT = WALL_BP .. "BP_BagTeleport.BP_BagTeleport_C"
    -- Short class names for the per-world seed (FindAllOf takes the short name). Every
    -- variant is listed rather than trusting FindAllOf to include subclasses; the
    -- address dedupe in upsert makes an overlap free.
    -- v0.16.5: the flower chest joins the seed. Her 19:20 run proved every one of its
    -- signals (three SpartaApplyHit, DisableTargeting and DropItem on the third,
    -- SaveItemCollected + OnItemPickedUp on the pickup) and also that its BeginPlay
    -- hook can never see the first world's plants: the class loads with the level that
    -- holds them, so they have begun play before Arm() can register on it.
    -- `collision` names the component whose collision the game switches off when the
    -- plant is spent -- the third of the three state reads (see plant_spent_state).
    -- v0.18.20: `category` is the switch that decides whether this class is worth
    -- ENUMERATING, and it is read before FindAllOf rather than after. Until v0.18.20 the
    -- only gate was inside note_wall/note_trap_like, which run on what the scan already
    -- returned -- so a player who had turned hidden walls off paid all seven 9.3 ms scans
    -- on every streamed re-seed and had every result thrown away. The category keys must
    -- match what the classifier actually assigns: the five wall classes are "Secret", and
    -- both plants reach note_trap_like with the "shootable" hint, which is "Loot".
    local WALL_SEED_CLASSES = {
        { class = "BP_HiddenWall_C", kind = "wall", category = "Secret" },
        { class = "BP_HiddenWall_Base_Natural_Rock_C", kind = "wall", category = "Secret" },
        { class = "BP_HiddenWall_Base_Natural_Rock_CannonBall_C", kind = "wall", category = "Secret" },
        { class = "BP_HiddenWall_Spikes_C", kind = "wall", category = "Secret" },
        { class = "BP_DestructiblePlaceholderWall_C", kind = "wall", category = "Secret" },
        { class = "BP_FlowerChest_C", kind = "hittable", collision = "HitDetectionCollision", category = "Loot" },
        { class = "BP_AttackFlower_C", kind = "hittable", collision = "Capsule", category = "Loot" },
    }
    -- Construction notifications: one per family (derived classes are included --
    -- the v0.9.0 recorder's "/Script/Engine.Actor" notify listed Blueprint actors).
    -- v0.18.20: `classes` is the set this notify can possibly be about. A construction
    -- of a rubble wall says nothing about flower chests, and re-seeding all seven on one
    -- notify was six scans of pure waste per streamed section.
    local WALL_NOTIFY_SPECS = {
        { label = "hiddenWall.construct", path = HIDDEN_WALL, classes = {
            "BP_HiddenWall_C", "BP_HiddenWall_Base_Natural_Rock_C",
            "BP_HiddenWall_Base_Natural_Rock_CannonBall_C", "BP_HiddenWall_Spikes_C" } },
        { label = "rubbleWall.construct", path = RUBBLE_WALL, classes = {
            "BP_DestructiblePlaceholderWall_C" } },
        { label = "flowerChest.construct", path = FLOWER_CHEST, classes = { "BP_FlowerChest_C" } },
        { label = "attackFlower.construct", path = ATTACK_FLOWER, classes = { "BP_AttackFlower_C" } },
    }
    -- A notify-driven re-seed waits this long for the streamed level to finish
    -- serialising the actor, and never runs more often than the floor per world.
    local WALL_RESEED_DELAY_MS = 600
    local WALL_RESEED_FLOOR_SECONDS = 3.0
    -- v0.18.20: once every wall hook and notify is armed, a streamed-in wall has its own
    -- ReceiveBeginPlay to announce it (source 2 of the three below), so the re-seed is a
    -- backstop rather than the mechanism and can be rare. Before arming completes it is
    -- the ONLY source, so the short floor stays. A sustained stream used to re-seed every
    -- 3 s for as long as constructions kept firing.
    local WALL_RESEED_ARMED_FLOOR_SECONDS = 25.0
    local WALL_SEED_SLICE_MS = 150
    -- Late arming, for a session that first meets a wall class mid-world: the retry
    -- ladder the area-name layer uses, stopped as soon as everything is armed.
    local WALL_ARM_RETRY_MS = { 5000, 15000, 40000, 90000 }
    local HOOK_SPECS = {
        -- Capture handler owners at initialization so discovery does not depend on
        -- prompt-range RegisterInteractable timing. Initialize/CustomInitialize
        -- share one persistent lifecycle source and ReceiveEndPlay retires it.
        { label = "handler.Initialize", path = HANDLER .. ":Initialize", kind = "handler-lifecycle-begin" },
        { label = "handler.CustomInitialize", path = HANDLER .. ":CustomInitialize", kind = "handler-lifecycle-begin" },
        { label = "handler.ReceiveEndPlay", path = HANDLER .. ":ReceiveEndPlay", kind = "handler-lifecycle-end" },
        { label = "handler.RegisterInteractable", path = HANDLER .. ":RegisterInteractable", kind = "handler-register" },
        { label = "handler.UnregisterInteractable", path = HANDLER .. ":UnregisterInteractable", kind = "handler-unregister" },
        -- v0.10.11 interactability state (BPC_InteractionHandler FModel export).
        -- Disable/Enable gate the marker. Invalidate and Lock/Unlock are evidence
        -- only (v0.10.14: the 2026-09-11 v0.10.13 run showed Invalidate on the
        -- Blacksmith, Milos, Vratko, Thestus, sit spots and traversal points after
        -- ordinary use, with no matching Enable; gating on it hid usable NPCs).
        { label = "handler.DisableInteractions", path = HANDLER .. ":DisableInteractions", kind = "handler-disable" },
        { label = "handler.EnableInteractions", path = HANDLER .. ":EnableInteractions", kind = "handler-enable" },
        { label = "handler.Invalidate", path = HANDLER .. ":Invalidate", kind = "handler-invalidate" },
        { label = "handler.LockInteraction", path = HANDLER .. ":LockInteraction", kind = "handler-lock" },
        { label = "handler.UnlockInteraction", path = HANDLER .. ":UnlockInteraction", kind = "handler-unlock" },
        { label = "interaction.ReceiveBeginPlay", path = INTERACTION .. ":ReceiveBeginPlay", kind = "actor-begin" },
        { label = "interaction.ReceiveEndPlay", path = INTERACTION .. ":ReceiveEndPlay", kind = "actor-end" },
        -- NPC interaction components initialize only when their native prompt
        -- activates. Capture the loaded actor at BeginPlay so the minimap's own
        -- range, rather than the game's short interaction radius, controls it.
        { label = "npc.ReceiveBeginPlay", path = NPC .. ":ReceiveBeginPlay", kind = "actor-begin" },
        -- v0.10.9: NPC actor end-of-life. BP_NPC_C does not override ReceiveEndPlay,
        -- so its instances execute the parent BP_AICharacter_C implementation. Two
        -- NPCs override it themselves (ObjectDump), so they get their own hooks.
        -- The callback performs only an address lookup against existing records;
        -- ordinary enemies exit after one GetAddress with no class/name/location read.
        { label = "ai.ReceiveEndPlay", path = AI_CHARACTER .. ":ReceiveEndPlay", kind = "owner-end" },
        -- v0.11.2 enemy layer. v0.11.0 wired this to Aggro (not a UFunction at all)
        -- and CharacterAggro_Event / CharacterAttack_Event, which armed cleanly and
        -- then fired exactly zero times across an eleven-minute session with 34
        -- deaths: they exist on the class but nothing calls them. ReceiveBeginPlay is
        -- the one event every AI character certainly runs, so that is the source now
        -- (user decision: enemies show from spawn), and the refresh hooks below are
        -- opportunistic -- each one is counted per label, so the next run says which
        -- of them the game actually calls without the layer depending on any of them.
        { label = "ai.ReceiveBeginPlay", path = AI_CHARACTER .. ":ReceiveBeginPlay", kind = "enemy-seen" },
        -- v0.11.3: these four are the unproven ones, and they are now switchable
        -- without touching the layer. The 2026-09-12 crash happened one tenth of a
        -- second after gameplay resumed with enemies walking at the player, which is
        -- exactly when an AI resumes its behaviour tree and these start firing, so
        -- `EnemyRefreshHooks=0` in the ini turns their work off while spawn-sourced
        -- dots keep working.
        { label = "ai.OnEncounterStarted", path = AI_CHARACTER .. ":OnEncounterStarted", kind = "enemy-seen", refresh = true },
        { label = "ai.SpartaApplyHit", path = AI_CHARACTER .. ":SpartaApplyHit", kind = "enemy-seen", refresh = true },
        { label = "ai.UpdateFightTarget", path = AI_CHARACTER .. ":UpdateFightTarget", kind = "enemy-seen", refresh = true },
        { label = "ai.PushPlayer", path = AI_CHARACTER .. ":PushPlayer", kind = "enemy-seen", refresh = true },
        -- v0.12.2. Her dungeon run: two enemies walked at her and their dots stayed at
        -- the spawn point, because every refresh hook above fires on CONTACT
        -- (OnEncounterStarted once, PushPlayer 699 times but only while touching) and
        -- nothing fires while an enemy simply walks. PlayFootstepVFX is the AI's own
        -- footstep: it fires exactly when the actor moves, a few times a second per
        -- moving enemy, never for one standing still, and the actor is fully alive
        -- mid-stride. Unproven until a run says it fires (invariant 0c) -- which is
        -- what the histogram is for -- and if it turns out to be per-frame the
        -- governor retires it (0i). The 0.2 s per-record throttle bounds the reads.
        { label = "ai.PlayFootstepVFX", path = AI_CHARACTER .. ":PlayFootstepVFX", kind = "enemy-seen", refresh = true },
        -- v0.16.9. Her 10:29 run (bundle 102937): three enemies walked at her and their
        -- dots stayed at the spawn point. The log names the classes that never get a
        -- refresh from any hook above -- BP_Batman_C (7 admitted, 0 refreshed; it flies,
        -- so PlayFootstepVFX never fires), BP_TarredVestige_C (8 / 0), BP_StoneCrab_C,
        -- BP_Cultist_Base_C -- while the walkers (Brigands, ToxicStalker, BabyEnemy)
        -- refreshed fine. The base SpartaCharacter carries movement-derived natives the
        -- footstep path does not need: the foley system (cloth / movement sound) watches
        -- every character's velocity and fires OnFoleyLinearVelocityChangeExceedThreshold
        -- when it changes enough, PlayFoleyLoop / UpdateFoleyParams while it moves, and
        -- OnFootDown / HandleFootDown are the raw foot events behind the VFX; the
        -- SpartaAICharacter parent adds OnPreAggro / OnAggro, the moment an AI turns on
        -- you. All unproven (0c) -- the histogram says which fire and the governor
        -- retires any that turn out per-frame (0i). Each one that fires is one bounded,
        -- throttled location read like the footstep path.
        -- v0.18.23: ALL EIGHT OF THOSE WERE AIMED AT THE WRONG CLASS and never armed
        -- once, in any world, from v0.16.9 until now. Every arm attempt in her 130041 log
        -- reads `state=pending error=... no UFunction with the specified name was found`.
        -- Read the paragraph above again: it says "the base SpartaCharacter carries" and
        -- "the SpartaAICharacter parent adds" -- the reasoning named the right classes and
        -- then all eight specs were written against AI_CHARACTER anyway. Invariant 0f, and
        -- the most expensive version of it yet, because a wrong path does not crash: it
        -- logs one pending line and looks like patience for six versions.
        --
        -- Her 131942 autopsy, with the class chain printed as
        -- `<declaring class path>:<name>`, gives the real homes:
        --
        --   depth 2  /Game/Sparta/Core/AI/BP_AICharacter.BP_AICharacter_C   (67 fns)
        --   depth 3  /Script/Sparta.SpartaAICharacter                       (7 fns)
        --   depth 4  /Script/Sparta.SpartaCharacter                        (54 fns)
        --
        --   OnPreAggro, OnAggro                    -> SpartaAICharacter  (AI ONLY)
        --   OnFoleyLinearVelocityChangeExceedThreshold, PlayFoleyLoop,
        --   UpdateFoleyParams, OnUpdateFoleyParams,
        --   OnFootDown, HandleFootDown             -> SpartaCharacter    (AI *and* PLAYER)
        --
        -- The aggro pair is restored here because SpartaAICharacter is the AI branch: the
        -- player is a BP_PlayerCharacter_C and does not inherit it, so these cannot fire
        -- for her. They are not a continuous movement signal -- they fire when an AI turns
        -- on you -- so they help a bat that has noticed you and not one that is patrolling.
        --
        { label = "ai.OnPreAggro", path = SPARTA_AI_CHARACTER .. ":OnPreAggro", kind = "enemy-seen", refresh = true },
        { label = "ai.OnAggro", path = SPARTA_AI_CHARACTER .. ":OnAggro", kind = "enemy-seen", refresh = true },
        -- v0.18.24: the six on SpartaCharacter, armed as a MEASUREMENT (user's call:
        -- "arm them, measure, then decide"). These are the only continuous movement
        -- signal a flying enemy has -- the aggro pair above fires when a bat notices
        -- you, which does nothing for one that is patrolling, and the AI-only classes
        -- offer nothing else that is not per-frame (BP_AICharacter_C's ReceiveTick and
        -- PostSpawnMovement are both forbidden by 0i; PostSpawnMovement is what produced
        -- 57,932 callbacks in 84 seconds in v0.11.6).
        --
        -- The cost of being wrong is bounded three ways and none of them makes the rate
        -- KNOWN: note_enemy drops the player on an address compare (enemySelfSkipped),
        -- the governor retires a label over 90/s for three windows or 450 in one, and a
        -- refresh-kind label gets a 1/60 s floor. So this ships to be measured, not
        -- trusted: read `hookEvents fired=` and `hook.ai.*` in [PERF] on the next dump.
        -- If any of them is hot, it comes out -- and if the governor beat us to it the
        -- hotHooks field says so rather than leaving bats quietly frozen again.
        -- v0.18.25: MEASURED, and four of the six are gone. Her 133801 run, one dump:
        --
        --   ai.OnUpdateFoleyParams  23867 events   <- PER FRAME. governor: hot, retired.
        --   ai.OnFootDown             276 events
        --   ai.OnFoleyVelocity         58 events
        --   ai.PlayFoleyLoop            0 events   <- armed, never called
        --   ai.UpdateFoleyParams        0 events   <- armed, never called
        --   ai.HandleFootDown           0 events   <- armed, never called
        --
        -- OnUpdateFoleyParams is exactly the PostSpawnMovement mistake of v0.11.6: it ran
        -- 422 times a second, the governor marked it hot and retired it (governorRejected
        -- climbed past 21,000) and busyPct sat at 6-14% against a 2.72% baseline. The
        -- governor working is not a reason to ship it. The three silent ones are removed
        -- too -- an armed hook that never fires is an arming probe and a line of log noise
        -- to prove nothing.
        --
        -- The two that stay are the two that did the job, and this is the payoff for the
        -- whole flying-enemy hunt:
        --
        --   enemyRefresh class=BP_Batman_C   total=13  by=OnFoleyVelocity:8|OnAggro:2|...
        --   enemyRefresh class=BP_StoneCrab_C total=102 by=OnFootDown:89|PlayFootstepVFX:4|...
        --
        -- OnFoleyVelocity is what finally moves a bat's dot -- the thing broken since
        -- v0.16.9 -- and OnFootDown took the crabs from 4 refreshes to 89. Both are cheap:
        -- 58 and 276 events with avg=0.15 ms and 0.36 ms per call.
        { label = "ai.OnFoleyVelocity", path = SPARTA_CHARACTER .. ":OnFoleyLinearVelocityChangeExceedThreshold", kind = "enemy-seen", refresh = true },
        { label = "ai.OnFootDown", path = SPARTA_CHARACTER .. ":OnFootDown", kind = "enemy-seen", refresh = true },
        -- v0.11.6 armed PostSpawnMovement and ShowWeaponPostSpawn here to correct a
        -- stale spawn position. Both are gone in v0.11.7 on her 12:49 run's evidence:
        -- `PostSpawnMovement` is not a spawn step at all but a per-tick function --
        -- 57,932 callbacks in 84 seconds across eight AI, about 86/s each, i.e. frame
        -- rate -- and `ShowWeaponPostSpawn` fired zero times. The crash at the end of
        -- that run faulted one call after a `phase=enemy-live` breadcrumb, so the
        -- per-frame reflection on mid-behaviour AI is also the best crash candidate we
        -- have had. The name of a UFunction says nothing about how often it is called;
        -- the governor below is what makes that safe to be wrong about.
        { label = "ai.DeathEvent", kind = "enemy-dead",
            path = AI_CHARACTER .. ":BndEvt__BP_AICharacter_HealthComponent_K2Node_ComponentBoundEvent_0_SpartaHealth_DeathEvent__DelegateSignature" },
        { label = "ai.DespawnEnemy", path = AI_CHARACTER .. ":DespawnEnemy", kind = "enemy-dead" },
        -- v0.11.3 evidence: CheckCorpseRemoval fired 73 times in one session against 3
        -- DeathEvents. It is the periodic "should this corpse go yet?" check, not the
        -- removal itself, so treating it as a death retired every living enemy as fast
        -- as it was admitted -- which is exactly why 30 admitted enemies drew no dots.
        -- v0.16.3 (user, 2026-09-13: "have red dots disappear when an enemy's hp hits
        -- 0 -- some enemies don't despawn"): her two BP_Hutchback_C corpses kept their
        -- dots because neither DeathEvent nor DespawnEnemy ever fired for them. The
        -- check is still not a death by itself, but it IS the one callback the game
        -- keeps making on a corpse, so it is where the health component gets asked --
        -- SpartaHealthComponent:IsDeadOrDying(), once per AI every CORPSE_READ_INTERVAL,
        -- only for an AI that already has a dot. A read that fails counts and changes
        -- nothing (invariant 0b).
        { label = "ai.CheckCorpseRemoval", path = AI_CHARACTER .. ":CheckCorpseRemoval", kind = "corpse-check" },
        -- Counted only, until a run says which of these the Hutchback's death calls
        -- (object dump 2026-09-12 lists them on BP_AICharacter_C). Whichever fires at
        -- HP 0 for every AI is the read-free signal that would replace the read above.
        { label = "ai.OnCharacterDeath", path = AI_CHARACTER .. ":OnCharacterDeath", kind = "probe" },
        { label = "ai.CharacterDeath_Event", path = AI_CHARACTER .. ":CharacterDeath_Event", kind = "probe" },
        { label = "ai.SetDeathResources", path = AI_CHARACTER .. ":SetDeathResources", kind = "probe" },
        { label = "ai.CanEnterPreDeathState", path = AI_CHARACTER .. ":CanEnterPreDeathState", kind = "probe" },
        -- v0.11.2 traps and shootable props. The lock-on component's own BeginPlay is
        -- the discovery source: every env-shooting object owns one, and the component
        -- knows its actor. The BP_BearTrap_C functions below are the state signals,
        -- and Activate is counted only until we know whether it means "armed" or
        -- "sprung" for this class.
        { label = "envShooting.ReceiveBeginPlay", path = LOCKON_ENV .. ":ReceiveBeginPlay", kind = "env-shooting-begin" },
        { label = "bearTrap.ListenToPlayerDeath", path = BEAR_TRAP .. ":ListenToPlayerDeath", kind = "trap-begin" },
        { label = "bearTrap.RearmTrap", path = BEAR_TRAP .. ":RearmTrap", kind = "trap-begin" },
        { label = "bearTrap.Activate", path = BEAR_TRAP .. ":Activate", kind = "probe" },
        -- v0.14.4 env-shooting retirement. Until now this family had an admission hook
        -- and no retirement hook at all, so an exploded barrel kept its marker for the
        -- rest of the world -- 438 admissions in one 35-minute run against a 64-icon
        -- budget, which is also how live markers get crowded out. BP_ExplosiveBarrel_C
        -- has no ReceiveEndPlay: the actor is not destroyed by exploding, which is why
        -- nothing we already hooked could ever have caught it.
        -- v0.16.7: Explode is the whole story -- it fired 50 times for 50 retirements in
        -- her 87-minute run (bundles 171559/175027/175424) while BreakEnvObject on both
        -- classes, DeleteEnvObject, HideEnvObject and TriggerEnvObject fired zero times
        -- through 40 explosions. Those five are gone; nothing else in this family has
        -- ever been seen to fire.
        { label = "explosiveBarrel.Explode", path = EXPLOSIVE_BARREL .. ":Explode", kind = "owner-retire", reason = "barrel-exploded" },
        -- v0.18.1 env-shooting state (see ENV_OBJECT_BASE). "env-state" re-reads the
        -- object's flags on the function's return and retires a spent one (or clears
        -- the memory of one the game reset); "env-retire" is a call that means spent
        -- by itself, remembered by address whether or not a record exists yet, since
        -- the restore at load can land before the lock-on BeginPlay that admits.
        { label = "envObject.OnWorldStateLoaded", path = ENV_OBJECT_BASE .. ":OnWorldStateLoaded", kind = "env-state", post = true },
        { label = "envObject.GotESOactivated", path = ENV_OBJECT_BASE .. ":GotESOactivated", kind = "env-state", post = true },
        { label = "envObject.Activate", path = ENV_OBJECT_BASE .. ":Activate", kind = "env-state", post = true },
        { label = "envObject.ActivationFinished", path = ENV_OBJECT_BASE .. ":ActivationFinished", kind = "env-state", post = true },
        { label = "envObject.SpartaApplyHit", path = ENV_OBJECT_BASE .. ":SpartaApplyHit", kind = "env-state", post = true },
        { label = "envObject.InvalidateCollision", path = ENV_OBJECT_BASE .. ":InvalidateCollision", kind = "env-retire", reason = "env-collision-invalidated" },
        -- "Invalidate" is ambiguous in this game (the interaction handlers' Invalidate
        -- fires for lifts and shopkeepers too, v0.11.2), so it reads the flags rather
        -- than retiring on its name; the breadcrumb says what it means for a torch.
        { label = "envObject.Invalidate", path = ENV_OBJECT_BASE .. ":Invalidate", kind = "env-state", post = true },
        { label = "bearTrap.TriggerTrap", path = BEAR_TRAP .. ":TriggerTrap", kind = "owner-retire", reason = "trap-sprung" },
        { label = "bearTrap.DisableTrap", path = BEAR_TRAP .. ":DisableTrap", kind = "owner-retire", reason = "trap-disabled" },
        { label = "bearTrap.PlayDisarmSFX", path = BEAR_TRAP .. ":PlayDisarmSFX", kind = "owner-retire", reason = "trap-disarmed" },
        { label = "blacksmith.ReceiveEndPlay", path = BLACKSMITH .. ":ReceiveEndPlay", kind = "owner-end" },
        { label = "genessaTraining.ReceiveEndPlay", path = GENESSA_TRAINING .. ":ReceiveEndPlay", kind = "owner-end" },
        -- v0.10.10: opened chests and collected pickups stay alive (handler neither
        -- unregisters nor ends play; v0.10.9 captures), so their icons lingered.
        -- These are the game's own completion functions (ObjectDump/FModel). Each
        -- override is hooked separately because a child override may not call its
        -- parent. Callback = one address lookup against existing records.
        { label = "chest.OnOpenComplete", path = CHEST .. ":OnOpenComplete", kind = "owner-retire", reason = "chest-opened" },
        { label = "chestSkin.OnOpenComplete", path = CHEST_SKIN .. ":OnOpenComplete", kind = "owner-retire", reason = "chest-opened" },
        { label = "chest.OnChestOpen", path = CHEST .. ":OnChestOpen", kind = "owner-retire", reason = "chest-opened" },
        { label = "chestGeneral.OnChestOpen", path = CHEST_GENERAL .. ":OnChestOpen", kind = "owner-retire", reason = "chest-opened" },
        { label = "chestSkin.OnChestOpen", path = CHEST_SKIN .. ":OnChestOpen", kind = "owner-retire", reason = "chest-opened" },
        { label = "chestSeal.OnChestOpen", path = CHEST_SEAL .. ":OnChestOpen", kind = "owner-retire", reason = "chest-opened" },
        { label = "pickupBase.PickUp", path = PICKUP_BASE .. ":PickUp", kind = "owner-retire", reason = "pickup-collected" },
        { label = "craftingPickup.PickUp", path = PICKUP_CRAFTING .. ":PickUp", kind = "owner-retire", reason = "pickup-collected" },
        { label = "currencyBag.PickUp", path = PICKUP_CURRENCY .. ":PickUp", kind = "owner-retire", reason = "pickup-collected" },
        { label = "artifact.PickUp", path = PICKUP_ARTIFACT .. ":PickUp", kind = "owner-retire", reason = "pickup-collected" },
        { label = "craftingPickup.SetAsCollected", path = PICKUP_CRAFTING .. ":SetAsCollected", kind = "owner-retire", reason = "pickup-collected" },
        { label = "currencyBag.SetAsCollected", path = PICKUP_CURRENCY .. ":SetAsCollected", kind = "owner-retire", reason = "pickup-collected" },
        { label = "currencyGold.PickUp", path = "/Game/Sparta/Core/Common/Currency/BP_Currency_Gold.BP_Currency_Gold_C:PickUp", kind = "owner-retire", reason = "pickup-collected" },
        -- v0.16.0 hidden walls. Begin-play admission where the class overrides it;
        -- DisableCollision / the rubble's item spawn as the open signal (v0.16.1, user
        -- decision: the marker leaves once the wall is open -- an icon with no purpose is
        -- clutter); the rest counted until a run says what they mean (invariant 0c).
        { label = "hiddenWallRock.ReceiveBeginPlay", path = HIDDEN_WALL_ROCK .. ":ReceiveBeginPlay", kind = "secret-begin" },
        { label = "hiddenWallCannon.ReceiveBeginPlay", path = HIDDEN_WALL_CANNON .. ":ReceiveBeginPlay", kind = "secret-begin" },
        { label = "hiddenWall.DisableCollision", path = HIDDEN_WALL .. ":DisableCollision", kind = "secret-open", reason = "wall-revealed" },
        { label = "rubble.ManualSpawnItem", path = RUBBLE_BASE .. ":ManualSpawnItem", kind = "secret-open", reason = "wall-broken" },
        { label = "rubble.PercentageSpawnItem", path = RUBBLE_BASE .. ":PercentageSpawnItem", kind = "secret-open", reason = "wall-broken" },
        { label = "hiddenWall.FadeMaterialOpacity", path = HIDDEN_WALL .. ":FadeMaterialOpacity", kind = "probe" },
        { label = "hiddenWall.SpartaApplyHit", path = HIDDEN_WALL .. ":SpartaApplyHit", kind = "probe" },
        { label = "hiddenWall.ShouldReveal", path = HIDDEN_WALL .. ":ShouldReveal", kind = "probe" },
        { label = "hiddenWall.SolutionTriggered", path = HIDDEN_WALL .. ":SolutionTriggered", kind = "probe" },
        { label = "hiddenWall.ProximityOverlap", path = HIDDEN_WALL_PROXIMITY, kind = "probe" },
        { label = "rubble.SpartaApplyHit", path = RUBBLE_BASE .. ":SpartaApplyHit", kind = "probe" },
        -- ====================================================================
        -- SETTLED (v0.18.19). Breaking a BP_DestructiblePlaceholderWall_C runs NO
        -- Blueprint. Eight read points were armed on its family across two runs, on two
        -- different walls in two areas -- OnBrokenEvent, RemoveTargetingCollision,
        -- Cleanup, GetHitResponse, GetStoppingDistanceOffset, SpartaApplyHit, the
        -- Blueprint's own binding to Chaos's OnChaosBreakEvent, and
        -- ExecuteUbergraph_BP_VFX_Breakable, which EVERY Blueprint event on that class
        -- runs through. All eight armed. None ever fired. Chaos destroys the components
        -- natively and nothing tells Lua. The 1 Hz re-check below is the mechanism.
        -- Do not spend another day looking for the event. The history is kept underneath
        -- because four versions of it were wrong for interesting reasons.
        -- (BP_HiddenWall_* is a different family and DOES signal -- those hooks fire.)
        -- ====================================================================
        --
        -- v0.18.4 asked whether BP_DestructiblePlaceholderWall_C overrides the three
        -- functions above -- because a hook on a base UFunction can never fire for a
        -- derived class that declares its own. v0.18.6 has the answer and it is NO. Her
        -- 094013 run: all three derived specs came back "no UFunction with the specified
        -- name was found", and the autopsy's function list for that class is four entries
        -- long -- ExecuteUbergraph, GetHitResponse, GetStoppingDistanceOffset,
        -- WasRecentlyRendered. No BeginPlay, no hit handler, no spawn functions. The same
        -- run also showed BP_DestructiblePlaceholder_C with ZERO instances and its hooks
        -- still "class not loaded", so in that world the base was never even hooked.
        --
        -- So this wall does not break through Blueprint at all, and there is most likely
        -- no function to hook on either class. The retirement has to come from a STATE
        -- READ, the same shape as the v0.16.6 plant fix -- which is what the autopsy's
        -- component dump is for. The derived specs are removed rather than left pending:
        -- a spec that is known not to exist is noise in every future log.
        --
        -- v0.18.8: the state read exists now (rubble_wall_broken). These two are the only
        -- functions the class declares that anything could plausibly call -- the autopsy's
        -- list in full is ExecuteUbergraph | GetHitResponse | GetStoppingDistanceOffset |
        -- WasRecentlyRendered -- so they are hooked NOT for what they mean but as the
        -- cheapest moments to re-read the state: a hook that hands us the actor costs
        -- nothing, where re-finding it would cost a 10 ms FindAllOf. Post-hooks, so the
        -- read sees what the call produced. If either name is wrong UE4SS says so and the
        -- spec stays pending, exactly as the three removed ones did.
        -- v0.18.10: the paths, from her 102234 run, which printed the class chain at last.
        -- BP_DestructiblePlaceholderWall_C declares ZERO functions of its own. Its parents
        -- are a breakables family nobody had seen:
        --
        --   1 BP_DestructiblePlaceholderWall_C              functions=0
        --   2 BP_VFX_Breakable_C   /Game/Sparta/FX/Systems/Breakables/...  GetStoppingDistanceOffset
        --   3 BP_VFX_Physical_C    /Game/Sparta/FX/Systems/Breakables/...  GetHitResponse
        --   4 /Script/Engine.Actor                          WasRecentlyRendered
        --   5 /Script/CoreUObject.Object                    ExecuteUbergraph
        --
        -- So GetHitResponse was real all along and belongs to BP_VFX_Physical_C, and the
        -- "ExecuteUbergraph" in the autopsy's flat list was the native UObject stub, not a
        -- Blueprint event graph -- hooking THAT would fire for every object in the game.
        -- This is what invariant 0f costs when the list stops saying where a name came
        -- from: three versions aimed at the wrong class.
        --
        -- Both of these are shared bases, so the handler gates on "do we already track a
        -- record for this actor" before it reads anything: for every other breakable in
        -- the game the hook costs one address read and one table lookup.
        -- v0.18.17: the real list, at last. v0.18.15 fixed the reflection walk (every
        -- callback used to return a value, and UE4SS reads any return as STOP, so every
        -- function list this project ever produced was ONE ENTRY DEEP). With it fixed,
        -- BP_VFX_Breakable_C has 26 functions, not 1, and they include exactly what six
        -- versions of "there is no event" said did not exist:
        --
        --     OnBrokenEvent
        --     OnBroken__DelegateSignature
        --     CustomBreak / BreakableHit / Cleanup
        --     RemoveTargetingCollision      <- removes one of the two components we read
        --     BndEvt__..._OnChaosBreakEvent__DelegateSignature
        --
        -- OnBrokenEvent is the break. RemoveTargetingCollision is the function that does
        -- the thing the state read detects. The last is the Blueprint's own binding to
        -- Chaos's break event on the geometry collection. All three are read points: the
        -- handler still confirms with the component read rather than trusting the name, so
        -- a wrong guess about what a function means cannot retire a standing wall.
        -- v0.18.18: all five of v0.18.17's read points ARMED (pre=95..99) and none of them
        -- FIRED, on either wall in her 114449 run. So the class declaring OnBrokenEvent is
        -- not the same as the game calling it -- it is an event dispatcher stub, and the
        -- work happens inside the Blueprint's event graph. Two more candidates, and this
        -- time one of them cannot miss:
        --
        --   * the Blueprint's own binding to Chaos's OnChaosBreakEvent on the geometry
        --     collection -- the engine telling the wall it has shattered, which is as
        --     close to the moment as this game can get;
        --   * ExecuteUbergraph_BP_VFX_Breakable, which every Blueprint event on that class
        --     runs through, including whatever handles the break. It is the one hook that
        --     must fire. If it turns out to be per-frame the v0.11.7 governor retires it
        --     on its own, and the handler gates on "do we already track this actor" first,
        --     so for every other breakable in the game it costs an address read and a
        --     table lookup.
        --
        -- The 1 Hz re-check stays until one of these is proven to fire. It works: her
        -- 114449 run retired BOTH walls through it -- the one we have been testing on and
        -- a fresh one in another area -- so this is an optimisation, not a fix.
        -- v0.18.19: SETTLED. Eight read points were armed across this family over two
        -- runs -- OnBrokenEvent, RemoveTargetingCollision, Cleanup, GetHitResponse,
        -- GetStoppingDistanceOffset, SpartaApplyHit, the Blueprint's binding to Chaos's
        -- own OnChaosBreakEvent, and ExecuteUbergraph_BP_VFX_Breakable itself. Every one
        -- ARMED (pre=95..99) and NOT ONE FIRED, on two different walls in two areas.
        --
        -- The ubergraph is the decisive one: every Blueprint event on that class runs
        -- through it, and label_events counts an event BEFORE the governor can reject it
        -- (governorRejected=7, hotHooks=none, and no vfx label in the fired histogram at
        -- all). So the count is a true zero, not a throttle.
        --
        -- Breaking one of these walls executes NO Blueprint on BP_VFX_Breakable_C. Chaos
        -- destroys the components from native code and nothing tells Lua. There is no hook
        -- to find, and this is the evidence for saying so rather than the assumption I made
        -- three versions running when the reflection dump was one entry deep. The specs are
        -- removed: each cost an arming probe and a line of log noise to prove a negative
        -- that is now proven.
        --
        -- The 1 Hz re-check in wall_recheck_tick is therefore the mechanism, not a
        -- stopgap. It retired both walls correctly and costs one StaticFindObject per
        -- approach.
        -- v0.16.4 flower chests. Admitted at their own BeginPlay as a shootable pickup
        -- (the same icon as barrels: hit it, it gives); the marker leaves when the item
        -- drops (its own pickup marker takes over), when it is picked up, when the save
        -- says collected, or when the game stops it being targetable -- and a signal
        -- that lands before BeginPlay (the save applies from the component's own
        -- BeginPlay, which runs first) is remembered by address so a collected one never
        -- shows. SpartaApplyHit counted, to learn the three hits.
        { label = "flowerChest.ReceiveBeginPlay", path = FLOWER_CHEST .. ":ReceiveBeginPlay", kind = "hittable-begin", collision = "HitDetectionCollision" },
        { label = "flowerChest.DropItemFinished", path = FLOWER_CHEST .. ":DropItem__FinishedFunc", kind = "hittable-retire", reason = "item-dropped" },
        { label = "flowerChest.OnItemPickedUp", path = FLOWER_CHEST .. ":OnItemPickedUp", kind = "hittable-retire", reason = "item-collected" },
        { label = "flowerChest.SaveItemCollected", path = FLOWER_CHEST .. ":SaveItemCollected", kind = "hittable-retire", reason = "item-collected" },
        { label = "flowerChest.DisableTargeting", path = FLOWER_CHEST .. ":DisableTargeting", kind = "hittable-retire", reason = "targeting-disabled" },
        -- v0.16.6: a hit is read AFTER the game has processed it (`post`: the hook runs
        -- on the function's return, so HitsReceived and RewardExtracted are the values
        -- the hit produced). The state read is the retirement of last resort for a
        -- plant whose spent signal we have not hooked or that never fires; for the
        -- chest, DisableTargeting lands first on the third hit and this read finds the
        -- memory already set.
        { label = "flowerChest.SpartaApplyHit", path = FLOWER_CHEST .. ":SpartaApplyHit", kind = "hittable-hit", collision = "HitDetectionCollision", post = true },
        -- v0.16.6 attack flowers. Its own BeginPlay reads the state (the save applies from
        -- the component BeginPlays, which precede it); DisableFlower is the expected spent
        -- signal (0c: unproven until a run says so); the post-hook hit read stands in if
        -- it never comes. RestartFlower, read on return, is the regrow: it clears the
        -- spent memory and re-admits a plant whose state reads fresh. InitRegrow counted.
        { label = "attackFlower.ReceiveBeginPlay", path = ATTACK_FLOWER .. ":ReceiveBeginPlay", kind = "hittable-begin", collision = "Capsule" },
        { label = "attackFlower.DisableFlower", path = ATTACK_FLOWER .. ":DisableFlower", kind = "hittable-retire", reason = "flower-disabled" },
        { label = "attackFlower.SpartaApplyHit", path = ATTACK_FLOWER .. ":SpartaApplyHit", kind = "hittable-hit", collision = "Capsule", post = true },
        { label = "attackFlower.RestartFlower", path = ATTACK_FLOWER .. ":RestartFlower", kind = "hittable-regrow", collision = "Capsule", post = true },
        { label = "attackFlower.InitRegrow", path = ATTACK_FLOWER .. ":InitRegrow", kind = "probe" },
        -- v0.16.6 the teleport sack: Deactivate is the used signal (0c until seen); the
        -- handler paths above cover a used one at load if the game invalidates it.
        { label = "bagTeleport.Deactivate", path = BAG_TELEPORT .. ":Deactivate", kind = "owner-retire", reason = "bag-used" },
    }

    -- No retained actor references (v0.10.10). Kept as 0 for summary continuity.
    local DYNAMIC_REF_CAP = 0

    local runtime = {
        records = {},
        sources = {},
        hooks = {},
        hook_failures = {},
        dynamic_ref_count = 0,
        dynamic_token = 0,
        sync_pending = false,
        sync_token = 0,
        quarantined = true,
        world_generation = 0,
        saw_load_pre = false,
        bootstrap_done = false,
        metrics = {
            hook_events = 0,
            handler_lifecycle_begin = 0,
            handler_lifecycle_end = 0,
            handler_register = 0,
            handler_unregister = 0,
            actor_begin = 0,
            actor_end = 0,
            owner_end = 0,
            owner_end_retired = 0,
            owner_retire = 0,
            owner_retire_retired = 0,
            handler_disable = 0,
            handler_enable = 0,
            handler_invalidate = 0,
            enemy_events = 0, enemy_admitted = 0, enemy_refreshed = 0, enemy_self_skipped = 0,
            -- v0.18.25: how many of those were caught by the CLASS test rather than the
            -- address one -- i.e. during the window where state.player is nil. Non-zero is
            -- normal (it happens on every load); it is the number that proves the guard
            -- now closes that window instead of leaving it open.
            enemy_self_by_class = 0,
            -- v0.18.26: what the stale-marker poll actually did. Reads are the cost;
            -- missing is the backstop catching an actor the endplay hooks did not.
            enemy_poll_reads = 0, enemy_poll_missing = 0,
            enemy_deaths = 0, enemy_decayed = 0, enemy_skipped = 0,
            boss_admitted = 0, enemy_class_reads = 0, enemy_refresh_throttled = 0,
            enemy_refresh_disabled = 0,
            -- v0.11.7 governor
            hooks_retired = 0, governor_rejected = 0, refresh_rate_gated = 0,
            -- v0.18.11 wall re-check: how many walls carry a path, how many look-ups ran,
            -- how many found the actor already gone with its level.
            secret_recheck_tracked = 0, secret_recheck_looks = 0, secret_recheck_missing = 0,
            -- v0.18.14: how many StaticFindObject class probes Arm() actually spent.
            arm_lookups = 0,
            -- v0.18.22: how many times a pass stopped because it had spent its 10 ms
            -- rather than because it ran out of class probes. This is the number that
            -- says whether the load hitch actually got sliced up.
            arm_time_slices = 0,
            secret_recheck_resolves = 0,
            enemy_friendly_skipped = 0,
            env_shooting_events = 0, trap_admitted = 0, shootable_admitted = 0,
            trap_state_events = 0, invalidate_retired = 0, probe_events = 0,
            handler_lock = 0,
            handler_unlock = 0,
            hidden_at_capture = 0,
            admitted = 0,
            filtered = 0,
            duplicate_sources = 0,
            source_rebinds = 0,
            retired = 0,
            invalid_contexts = 0,
            quarantined_events = 0,
            sync_requests = 0,
            sync_coalesced = 0,
            dynamic_refresh_slices = 0,
            dynamic_refresh_reads = 0,
            dynamic_position_updates = 0,
            dynamic_invalid_reads = 0,
            dynamic_ref_cap_drops = 0,
            bootstrap_runs = 0,
            bootstrap_handler_candidates = 0,
            bootstrap_readtext_candidates = 0,
            bootstrap_cpu_ms = 0.0,
            world_resets = 0,
            -- v0.16.0 hidden walls
            secret_seeds = 0, secret_seed_candidates = 0, secret_seed_cpu_ms = 0.0,
            secret_admitted = 0, secret_retired = 0, secret_open_events = 0,
            secret_state_reads = 0, secret_state_open = 0, secret_state_unknown = 0,
            secret_location_pending = 0, secret_notify_events = 0, secret_reseeds = 0,
            secret_begin_events = 0,
            -- v0.18.20: what the settings gate saved. A scan refused before FindAllOf
            -- ran, a whole seed with nothing enabled to enumerate, and a construction
            -- notify for a family that is switched off.
            secret_seed_skipped = 0, secret_seeds_skipped = 0, secret_notify_skipped = 0,
            -- v0.16.3 corpse check
            corpse_checks = 0, corpse_reads = 0, corpse_dead = 0, corpse_read_failures = 0,
            -- v0.16.4 hittables
            hittable_admitted = 0, hittable_retired = 0, hittable_skipped = 0,
            -- v0.16.6 plant state reads
            hittable_state_reads = 0, hittable_state_spent = 0, hittable_state_unknown = 0,
            hittable_hits = 0, hittable_regrown = 0,
            -- v0.18.1 env-shooting state reads
            env_state_reads = 0, env_state_events = 0, env_state_retired = 0,
            env_spent_skipped = 0, env_state_unknown = 0, env_reset = 0,
            env_retire_events = 0, env_superseded = 0,
        },
        seen_classes = {},
        filtered_classes = {},
        retire_reasons = {},
        -- v0.11.2: one counter per hook label. This is how a hook that arms but is
        -- never called (CharacterAggro_Event, CharacterAttack_Event) gets caught in
        -- one run instead of a release.
        label_events = {},
        -- v0.11.7 hot-hook governor. See `governor_admits` below: one sliding-window
        -- counter per label, and the set of labels it has retired for this session.
        label_window = {},
        retired_labels = {},
        -- v0.11.7 trace budget: one counter per "label|phase" so a hook nobody
        -- expected to be hot cannot turn the log into 16 MB of one line.
        trace_budget = {},
        trace_window = {},
        last_churn_clock = nil,
        churn_deferrals = {},
        enemy_count = 0,
        enemy_sweep_armed = false,
        -- handler address -> reason ("disable"); survives until the
        -- handler is enabled, ends play, or the world changes. Lets a disable that
        -- arrives before capture still gate the record once it is captured.
        handler_disabled = {},
        state_events = {},
        -- v0.16.0 hidden walls. `notify` mirrors `hooks` for NotifyOnNewObject
        -- registrations (per session). `secret_open` is owner address -> reason for a
        -- wall the game has already opened, kept until the world changes, so an open
        -- signal that lands before the seed still marks the record once it exists --
        -- the same pre-capture memory as `handler_disabled`. The re-seed bookkeeping
        -- is per world: one pending timer and the clock of the last run.
        notify = {},
        notify_failures = {},
        secret_open = {},
        -- v0.18.14: class path -> true once seen loaded. Positive answers only, cleared
        -- with the world: a loaded class cannot unload under us, an absent one may arrive.
        class_present = {},
        -- v0.18.17: and the classes this world does not have. Cleared by a construction
        -- notify, which is the only evidence that something new was loaded.
        class_absent = {},
        class_absent_clears = 0,
        arm_continue_pending = false,
        -- v0.18.16: where the current Arm() pass stopped, nil when no pass is in flight.
        arm_cursor = nil,
        walls_were_armed = false,
        -- v0.18.13: owner address -> the resolved wall actor, held ONLY while the player
        -- is in range of it. See wall_recheck_tick: StaticFindObject measured 8-11 ms, so
        -- resolving once per approach instead of once per second is the difference
        -- between a dropped frame every second and none.
        wall_actors = {},
        -- v0.16.4: owner address -> reason for a hittable already spent, per world.
        hittable_done = {},
        -- v0.18.1: owner address -> reason for an env-shooting object already fired
        -- (a torch, a barrel) or invalidated, per world. The state read at admission
        -- outranks it whenever the read succeeds; it decides only when the read cannot.
        env_spent = {},
        -- v0.18.22: class -> { total, [hook label] = count }. Per world; the flying-enemy
        -- question is "does BP_Batman_C ever refresh, and from what", and this answers it.
        enemy_refresh_by_class = {},
        -- v0.18.26: owner address -> the actor wrapper a hook already handed us, so the
        -- stale-marker poll never performs a look-up. Validated on every use, dropped on
        -- retirement / failed validate / world reset, counted in retainedActorRefs.
        enemy_actors = {},
        enemy_poll_pending = false,
        enemy_poll_cursor = nil,
        -- v0.18.27: the generation a self-rescheduling tick was started in. A world reset
        -- clears the `pending` flags but CANNOT unqueue a job already sitting in
        -- WorkBudget, so the next admission started a second chain and both then
        -- rescheduled themselves for ever. Her 144224 run: two world loads, and
        -- schedule.discovery.enemy-poll settled at rate=4.0 against a designed 2 Hz.
        -- This is the same failure the wall-watch diagnostic had this morning, rebuilt
        -- in production hours later, so the fix is the same one: a tick whose epoch is
        -- stale returns WITHOUT rescheduling and without touching `pending`.
        tick_epoch = 0,
        -- v0.18.23: label -> path for a spec UE4SS says does not exist. Permanent, so it
        -- is NOT cleared per world: the name is wrong in the source, not missing in this
        -- level. The summary shouts about it (see deadHooks below).
        dead_hooks = {},
        secret_reseed_pending = false,
        secret_reseed_at = nil,
        secret_arm_retry_armed = false,
        -- v0.18.20: the class set a pending re-seed will cover. Notifies accumulate into
        -- it rather than being dropped, because with scoped re-seeds a dropped caller is
        -- a family that never gets seeded. `reseed_all_pending` is the "somebody asked
        -- for everything" flag, which swallows any narrower set.
        reseed_classes = nil,
        reseed_all_pending = false,
    }

    -- v0.11.3 crash breadcrumb. The 2026-09-12 access violation was inside a hook,
    -- in UE4SS's reflection path (fault at UE4SS+0x367445, one call site away from the
    -- v0.10.9 family), and a crash takes the process down before any summary is
    -- written -- so the only way to name the faulting call is to log each step as it
    -- happens. UE4SS flushes per line, so the last line in the log is the call that
    -- died. Covers the v0.11.2 hooks only, and `LocalDiscoveryTrace=0` in the ini
    -- turns it off once we have the answer.
    --
    -- v0.11.7 adds a budget. The 12:49 run wrote 115,864 trace lines for one label
    -- and produced a 16 MB log with no summary in it, because the breadcrumb has to
    -- be unbuffered to be worth anything and an unbuffered write per frame per actor
    -- is itself a cost. Each label/phase pair gets TRACE_BUDGET lines and then says
    -- once that it has stopped; the metrics below still count every event.
    -- v0.18.17 arm tunables. Declared HERE, above every use: note_wall_construction sits
    -- ~300 lines above class_loaded_checker, and a local declared below a use compiles to
    -- a nil global (invariant 0c). That is exactly what happened on the first cut of this
    -- change -- the notify callback died on `nil < nil` and the re-seed it owed never ran,
    -- which showed up as a flower chest that stopped being seeded.
    local ARM_LOOKUP_BUDGET = 2
    local ARM_CONTINUE_MS = 60
    -- A hard ceiling on class probes per world. Even with both caches, a bug in the
    -- invalidation logic must not be able to turn this into a treadmill again: this is the
    -- termination proof, not the termination hope.
    local ARM_PROBE_CEILING = 48
    -- How many times a construction notify may reopen the absent cache in one world.
    local WALL_ABSENT_CLEAR_LIMIT = 4
    -- v0.18.22: a TIME slice, because ARM_LOOKUP_BUDGET only bounds the class PROBES and
    -- the probes turned out not to be the whole cost. Her 130041 benchmark, with the
    -- diagnostic finally out of the way, put every one of the four worst hitches in this
    -- one function:
    --
    --   schedule.discovery.wall-arm-retry  max=135 ms   n=8   total=322 ms
    --   schedule.discovery.wall-reseed     max=125 ms   n=3   (its body is Arm())
    --   schedule.discovery.arm-continue    max= 82 ms   n=32  total=724 ms
    --   schedule.discovery.arm-retry       max= 82 ms   n=3
    --
    -- and her tick rate fell from 50.3/s to 16.8/s while an area loaded. The cause is that
    -- a world load makes many classes available at once, so ONE pass can walk most of the
    -- 88 specs calling RegisterHook on each -- and RegisterHook is not free. Two lookups
    -- was never the bound that mattered; wall-clock is. A pass now stops once it has spent
    -- this long and resumes from the cursor, so a load costs many short calls instead of a
    -- handful of frame-eating ones. Always at least one spec per pass, so it still
    -- terminates (the v0.18.14 lesson: a termination PROOF, not a hope).
    local ARM_TIME_SLICE_MS = 10.0

    -- v0.18.33. THE CRASH, named from the faulting instruction rather than from a
    -- breadcrumb. Five crashes, one stack, and disassembling UE4SS.dll at the reported
    -- offset settles what it is:
    --
    --   UE4SS+0x365610   call 0x35fe80          ; get the object's class
    --                    mov  rax,[rax]
    --                    cmp  rax,rbx           ; is it the class we want?
    --                    je   done
    --                    mov  rcx,rax
    --                    call 0x37f700          ; -> super-struct
    --   UE4SS+0x36562e   mov  rax,[rax]         ; <== FAULTS, rax = 0x40
    --
    -- That is a class-hierarchy walk -- IsA -- and its caller (UE4SS+0x274420) is a
    -- visitor that takes one object and returns 1, which is LoopAction::Continue. So the
    -- faulting code is UE4SS WALKING THE GLOBAL OBJECT ARRAY and type-testing each entry:
    -- the inside of FindAllOf / FindFirstOf / StaticFindObject. One entry belonged to an
    -- actor being torn down, its class pointer was garbage, and the super-struct walk
    -- dereferenced 0x40.
    --
    -- Nothing in Lua can make that safe. The only thing that can is NOT SCANNING while
    -- the array is being churned -- and every one of her five crashes landed within
    -- 0.1-1.7 s of a hook-arming pass, which probes classes by scanning, during a burst
    -- of 96 BeginPlays as an area streamed in. Her friend's v0.16.7 never crashes there
    -- because it has no late-arm ladder and no sliced arm continuation: v0.18.17 and
    -- v0.18.22 turned arming from a few passes into many, spread across exactly the
    -- window when the game is spawning and destroying actors. I built the collision.
    local CHURN_QUIET_SECONDS = 0.35
    -- A termination proof, not a hope (the v0.18.14 lesson): a busy area could otherwise
    -- defer a scan for ever. After this many consecutive deferrals the scan goes anyway.
    local CHURN_MAX_DEFERRALS = 12

    -- Set by every hook that means an actor arrived or left. One clock read and one
    -- assignment on those kinds; nothing on the movement hooks, which are the hot ones.
    local CHURN_KINDS = {
        ["actor-begin"] = true, ["actor-end"] = true, ["owner-end"] = true,
        ["handler-lifecycle-begin"] = true, ["handler-lifecycle-end"] = true,
        ["handler-register"] = true, ["handler-unregister"] = true,
        ["env-shooting-begin"] = true, ["secret-begin"] = true,
        ["hittable-begin"] = true, ["npc-begin"] = true,
    }

    -- True while the object array is being churned, so a scan must wait.
    local function churn_quiet(counter_key)
        local last = tonumber(runtime.last_churn_clock)
        if last == nil then return true end
        if (governor_clock() - last) >= CHURN_QUIET_SECONDS then
            runtime.churn_deferrals[counter_key] = 0
            return true
        end
        local used = (runtime.churn_deferrals[counter_key] or 0) + 1
        runtime.churn_deferrals[counter_key] = used
        if used > CHURN_MAX_DEFERRALS then
            runtime.metrics.churn_forced = (runtime.metrics.churn_forced or 0) + 1
            runtime.churn_deferrals[counter_key] = 0
            return true
        end
        runtime.metrics.churn_deferred = (runtime.metrics.churn_deferred or 0) + 1
        return false
    end

    local TRACE_BUDGET = 120
    -- v0.18.29: the budget is per WINDOW, not per session. v0.11.7 added it because one
    -- label wrote 115,864 lines and buried the summary, and that reason still holds -- but
    -- a per-session budget means a breadcrumb goes quiet forever the first time an area
    -- streams in, and then a crash forty minutes later has nothing to say. Her 21:22:34Z
    -- crash log shows exactly that: "trace suppressed label=handler.UnregisterInteractable
    -- after=120", twelve lines before the process died. A rolling window keeps the volume
    -- bounded AND keeps the last seconds before any crash readable, which is the entire
    -- purpose of a breadcrumb (invariant 0l: a diagnostic that cannot answer is only cost).
    local TRACE_WINDOW_SECONDS = 10.0

    local function trace(label, phase, extra)
        if Config.LocalDiscoveryTrace == false then return end
        local slot = tostring(label) .. "|" .. tostring(phase)
        local now = os.clock()
        local started = runtime.trace_window[slot]
        if started == nil or (now - started) >= TRACE_WINDOW_SECONDS then
            runtime.trace_window[slot] = now
            runtime.trace_budget[slot] = 0
        end
        local used = (runtime.trace_budget[slot] or 0) + 1
        runtime.trace_budget[slot] = used
        if used > TRACE_BUDGET then
            if used == TRACE_BUDGET + 1 then
                log("Local discovery trace suppressed label=" .. tostring(label)
                    .. " phase=" .. tostring(phase) .. " after=" .. tostring(TRACE_BUDGET)
                    .. " windowS=" .. tostring(TRACE_WINDOW_SECONDS))
            end
            return
        end
        log("Local discovery trace label=" .. tostring(label) .. " phase=" .. tostring(phase)
            .. (extra ~= nil and (" " .. tostring(extra)) or ""))
    end

    -- Hot-hook governor (v0.11.7) -------------------------------------------------
    -- The lesson of v0.11.6 is not that PostSpawnMovement was the wrong hook; it is
    -- that nothing in a UFunction's name, signature or neighbours tells you whether
    -- the game calls it once per spawn or once per frame, and the only way to find
    -- out has been to ship it and read her log. So the layer now measures itself:
    -- every callback counts its label in a one-second sliding window, in plain Lua,
    -- BEFORE the actor is unwrapped, and a label that exceeds the cap is retired for
    -- the rest of the session. A per-frame hook therefore costs one wasted second of
    -- table increments instead of a session of native reflection.
    --
    -- A single busy second is NOT evidence of a per-frame hook, and this distinction
    -- is what keeps the governor from breaking the layer it protects: when an area
    -- streams in, `handler.RegisterInteractable` and `handler.Initialize` fire once per
    -- interactable in a burst, and retiring either of those would silently delete local
    -- interactables. So there are two thresholds:
    --   * SUSTAINED: over 90 events/s for three consecutive one-second windows. A load
    --     burst is one window; a tick is every window.
    --   * RUNAWAY: over 450 events/s in a single window. Nothing legitimate we have
    --     measured comes near it (the busiest confirmed hook managed 161 events across
    --     84 seconds); her PostSpawnMovement flood ran at roughly 690/s and trips this
    --     inside the first second.
    local HOT_HOOK_EVENTS_PER_SECOND = 90
    local HOT_HOOK_WINDOWS = 3
    local RUNAWAY_EVENTS_PER_SECOND = 450
    -- Refresh hooks additionally get a floor on the gap between two serviced events, so
    -- even a legitimate hook that bursts cannot turn into per-frame native work while
    -- the governor is still deciding. This bounds the damage of being wrong to 60
    -- native reads a second for at most three seconds.
    local REFRESH_LABEL_MIN_GAP = 1.0 / 60.0

    local function retire_label(label, count, reason)
        runtime.retired_labels[label] = reason
        runtime.metrics.hooks_retired = runtime.metrics.hooks_retired + 1
        log("Local discovery hook retired label=" .. label
            .. " reason=" .. reason .. " events=" .. tostring(count)
            .. " cap=" .. tostring(HOT_HOOK_EVENTS_PER_SECOND) .. " window=1s")
    end

    local function governor_admits(label, refresh)
        label = tostring(label or "")
        if runtime.retired_labels[label] ~= nil then return false end
        local now = governor_clock()
        local window = runtime.label_window[label]
        if window == nil then
            window = { start = now, count = 0, streak = 0, serviced = nil }
            runtime.label_window[label] = window
        end
        if now - window.start >= 1.0 then
            -- Close the window that just ended and judge it on its own count.
            if window.count > HOT_HOOK_EVENTS_PER_SECOND then
                window.streak = window.streak + 1
            else
                window.streak = 0
            end
            window.start = now
            window.count = 0
            if window.streak >= HOT_HOOK_WINDOWS then
                retire_label(label, window.streak, "hot")
                return false
            end
        end
        window.count = window.count + 1
        if window.count > RUNAWAY_EVENTS_PER_SECOND then
            retire_label(label, window.count, "runaway")
            return false
        end
        if refresh == true then
            local serviced = window.serviced
            if serviced ~= nil and now - serviced < REFRESH_LABEL_MIN_GAP then
                runtime.metrics.refresh_rate_gated = runtime.metrics.refresh_rate_gated + 1
                return false
            end
            window.serviced = now
        end
        return true
    end

    -- Retired labels, sorted, for the summary. "none" is the expected value; anything
    -- else names a hook the game calls far more often than its name suggests, and is
    -- the answer to a report of a stutter or a crash that arrives with it.
    local function hot_hook_text()
        local out = {}
        for hook_label, reason in pairs(runtime.retired_labels) do
            out[#out + 1] = tostring(hook_label) .. ":" .. tostring(reason)
        end
        if #out == 0 then return "none" end
        table.sort(out)
        return table.concat(out, "|")
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

    local function location(actor)
        local pos = Object.ActorLocation(actor)
        if pos == nil then return nil end
        return { x = tonumber(pos.x), y = tonumber(pos.y), z = tonumber(pos.z) or 0.0 }
    end

    local function count_records()
        local n = 0
        for _ in pairs(runtime.records) do n = n + 1 end
        return n
    end

    local function request_sync(reason)
        runtime.metrics.sync_requests = runtime.metrics.sync_requests + 1
        if runtime.sync_pending then
            runtime.metrics.sync_coalesced = runtime.metrics.sync_coalesced + 1
            return true
        end
        runtime.sync_pending = true
        runtime.sync_token = runtime.sync_token + 1
        local token = runtime.sync_token
        local generation = runtime.world_generation
        return WorkBudget.Schedule(100, function()
            if token ~= runtime.sync_token or generation ~= runtime.world_generation then return end
            runtime.sync_pending = false
            if runtime.quarantined then return end
            if type(ctx.LocalPool) == "table" and type(ctx.LocalPool.SyncRecords) == "function" then
                ctx.LocalPool.SyncRecords(runtime.records, reason or "local-discovery")
            end
        end, "discovery.sync")
    end

    -- A record is shown only while it is interactable and visible (user rule,
    -- 2026-09-11): hidden actors and handlers with interactions disabled are
    -- suppressed, not deleted, so they reappear when the game re-enables them.
    -- The "only while visible and interactable" gate exists for interactables, where a
    -- hidden actor is a trigger volume you should not see a marker for. It is
    -- meaningless for a hostile: BP_AICharacter_C carries PostSpawnMovement,
    -- ShowWeaponPostSpawn and IsSpawnFinished, i.e. an AI is routinely bHidden at
    -- ReceiveBeginPlay and revealed a moment later -- and enemies have no interaction
    -- handler, so nothing ever re-evaluates the flag afterwards. That is what kept the
    -- 2026-09-12 12:28 run's fifteen admitted enemies off the map with
    -- `sync-enter reason=local-suppressed` in the log as the only clue.
    local function suppression_exempt(record)
        local category = tostring(record.category or "")
        return category == "Enemy" or category == "Boss"
    end

    local function refresh_suppression(record)
        if record == nil then return false end
        local disabled = type(record.disabled_by) == "table" and next(record.disabled_by) ~= nil
        local suppressed = (not suppression_exempt(record))
            and (record.hidden == true or disabled)
        if record.suppressed ~= suppressed then
            record.suppressed = suppressed
            request_sync(suppressed and "local-suppressed" or "local-unsuppressed")
            return true
        end
        return false
    end

    local function actor_hidden(actor)
        local hidden = nil
        pcall(function() hidden = actor.bHidden end)
        if type(hidden) ~= "boolean" then hidden = Object.AsBoolean(hidden) end
        return hidden == true
    end

    local function note_state(kind, class_name)
        local key = tostring(kind) .. ":" .. tostring(class_name or "<untracked>")
        runtime.state_events[key] = (runtime.state_events[key] or 0) + 1
    end

    local function retire_owner(owner_key, reason)
        local record = runtime.records[owner_key]
        if record == nil then return false end
        if type(record.source_keys) == "table" then
            for source_key in pairs(record.source_keys) do runtime.sources[source_key] = nil end
        end
        runtime.records[owner_key] = nil
        runtime.metrics.retired = runtime.metrics.retired + 1
        local reason_key = tostring(reason or "local-retire")
        runtime.retire_reasons[reason_key] = (runtime.retire_reasons[reason_key] or 0) + 1
        request_sync(reason or "local-retire")
        return true
    end

    local function remove_source(source_key, reason)
        local owner_key = runtime.sources[source_key]
        if owner_key == nil then return false end
        runtime.sources[source_key] = nil
        local record = runtime.records[owner_key]
        if record == nil then return false end
        if type(record.source_keys) == "table" then record.source_keys[source_key] = nil end
        record.source_count = math.max(0, (tonumber(record.source_count) or 1) - 1)
        if record.source_count <= 0 then return retire_owner(owner_key, reason) end
        return true
    end

    local function note_class(bucket, class_name)
        class_name = tostring(class_name or "<unknown>")
        bucket[class_name] = (bucket[class_name] or 0) + 1
    end

    local function upsert(source_key, actor, source_label, handler_hint)
        actor = Object.Unwrap(actor)
        if not Object.Valid(actor) then
            runtime.metrics.invalid_contexts = runtime.metrics.invalid_contexts + 1
            return nil, "actor-invalid"
        end
        local owner_key = Object.Address(actor)
        local class_name = Object.ClassShortName(actor)
        if owner_key == nil then
            runtime.metrics.invalid_contexts = runtime.metrics.invalid_contexts + 1
            return nil, "identity-unavailable"
        end

        note_class(runtime.seen_classes, class_name)
        -- v0.10.13: a shop handler ("merchant") outranks the NPC BeginPlay source.
        local source_hint = handler_hint
            or (source_label == "npc.ReceiveBeginPlay" and "npc" or nil)
        local hint_rank = Classifier.HintRank(source_hint)
        local policy, reject_reason = Classifier.Classify(class_name, source_hint)
        if policy == nil then
            runtime.metrics.filtered = runtime.metrics.filtered + 1
            note_class(runtime.filtered_classes, class_name)
            return nil, reject_reason
        end

        local previous_owner = runtime.sources[source_key]
        if previous_owner == owner_key and runtime.records[owner_key] ~= nil then
            runtime.metrics.duplicate_sources = runtime.metrics.duplicate_sources + 1
            return runtime.records[owner_key], nil
        end

        local actor_name = Object.ShortName(actor)
        local hidden = actor_hidden(actor)
        local pos = location(actor)
        if pos == nil then
            runtime.metrics.invalid_contexts = runtime.metrics.invalid_contexts + 1
            return nil, "location-unavailable"
        end

        if previous_owner ~= nil and previous_owner ~= owner_key then
            runtime.metrics.source_rebinds = runtime.metrics.source_rebinds + 1
            remove_source(source_key, "local-source-rebind")
        end

        local record = runtime.records[owner_key]
        local is_new = record == nil
        if is_new then
            record = {
                id = owner_key,
                class = tostring(class_name or "<unknown>"),
                name = tostring(actor_name or "<unnamed>"),
                category = policy.key,
                category_label = policy.label,
                priority = tonumber(policy.priority) or 100,
                dynamic = policy.dynamic == true,
                texture_path = policy.texture_path,
                tint = policy.tint,
                x = pos.x, y = pos.y, z = pos.z,
                source_count = 0,
                source_keys = {},
                source = tostring(source_label or "unknown"),
                generation = runtime.world_generation,
                invalid_refreshes = 0,
                hidden = hidden,
                disabled_by = {},
                suppressed = false,
                hint_rank = hint_rank,
            }
            if hidden then runtime.metrics.hidden_at_capture = runtime.metrics.hidden_at_capture + 1 end
            runtime.records[owner_key] = record
            runtime.metrics.admitted = runtime.metrics.admitted + 1
            -- Primitive-only: the actor wrapper is never stored.
            record.dynamic_tracked = false
        else
            -- A later live callback for the same owner refreshes position/visibility.
            record.x, record.y, record.z = pos.x, pos.y, pos.z
            record.hidden = hidden
            -- A handler may be captured before the NPC BeginPlay source arrives;
            -- the NPC source then upgrades the category (v0.10.12). v0.10.13: hints
            -- are ranked (merchant > npc > none) so a later, weaker source never
            -- downgrades a shop NPC back to NPC.
            if hint_rank > (tonumber(record.hint_rank) or 0) then
                record.hint_rank = hint_rank
                if record.category ~= policy.key or record.texture_path ~= policy.texture_path then
                    record.category, record.category_label = policy.key, policy.label
                    record.priority = tonumber(policy.priority) or record.priority
                    record.texture_path = policy.texture_path
                    record.tint = policy.tint
                    runtime.metrics.recategorized = (runtime.metrics.recategorized or 0) + 1
                    request_sync("local-recategorized")
                end
            end
            record.class = tostring(class_name or record.class)
            record.name = tostring(actor_name or record.name)
            if type(ctx.LocalPool) == "table" and type(ctx.LocalPool.UpdateRecordPosition) == "function" then
                ctx.LocalPool.UpdateRecordPosition(record)
            end
            state.local_overlay_refresh_requested = true
        end

        if runtime.sources[source_key] ~= owner_key then
            runtime.sources[source_key] = owner_key
            record.source_keys[source_key] = true
            record.source_count = record.source_count + 1
        end

        refresh_suppression(record)
        if is_new then request_sync("local-add") end
        return record, nil
    end

    local function source_key(kind, object)
        object = Object.Unwrap(object)
        local address = Object.Address(object)
        return address ~= nil and (tostring(kind) .. ":" .. tostring(address)) or nil
    end

    -- v0.10.13: shop handlers mark their owner as a merchant. Name read inside
    -- the live callback only ("BPC_Interaction_Shop" on BP_Merchant_C,
    -- "Shop Interaction Handler" on BP_ShopHandler_Tavern_C).
    local function handler_hint(component)
        local name = Object.ShortName(component)
        if name ~= nil and string.find(name, "Shop", 1, true) ~= nil then return "merchant" end
        local class_name = Object.ClassShortName(component)
        if class_name ~= nil and string.find(class_name, "Shop", 1, true) ~= nil then return "merchant" end
        return nil
    end

    local function capture_handler(component, source_label, source_kind)
        component = Object.Unwrap(component)
        if not Object.Valid(component) then
            runtime.metrics.invalid_contexts = runtime.metrics.invalid_contexts + 1
            return nil
        end
        local key = source_key(source_kind or "handler-register", component)
        local owner = component_owner(component)
        if key == nil or not Object.Valid(owner) then
            runtime.metrics.invalid_contexts = runtime.metrics.invalid_contexts + 1
            return nil
        end
        local hint = handler_hint(component)
        if hint ~= nil then runtime.metrics.shop_handlers = (runtime.metrics.shop_handlers or 0) + 1 end
        local record = upsert(key, owner, source_label, hint)
        local handler_addr = Object.Address(component)
        if record ~= nil and handler_addr ~= nil and runtime.handler_disabled[handler_addr] ~= nil then
            record.disabled_by[handler_addr] = runtime.handler_disabled[handler_addr]
            refresh_suppression(record)
        end
        return record
    end

    -- Owner record for a handler address, via the source map (no reflection).
    local function record_for_handler(handler_addr)
        if handler_addr == nil then return nil end
        local owner_key = runtime.sources["handler-lifecycle:" .. handler_addr]
            or runtime.sources["handler-register:" .. handler_addr]
        return owner_key ~= nil and runtime.records[owner_key] or nil
    end

    local function capture_actor(actor, source_label)
        actor = Object.Unwrap(actor)
        local key = source_key("actor", actor)
        if key == nil then
            runtime.metrics.invalid_contexts = runtime.metrics.invalid_contexts + 1
            return nil
        end
        return upsert(key, actor, source_label)
    end

    -- Enemy layer -------------------------------------------------------------
    -- Kept deliberately narrow: one class read on first sighting (to tell a boss
    -- from a regular), a location read per engagement event, and primitives only.
    local ENEMY_MOVE_RESYNC_SQ = 500.0 * 500.0 -- 5 m before asking the pool to reselect
    -- A refresh hook may turn out to be called very often (UpdateFightTarget could
    -- run per AI decision). One location read per enemy per interval caps the cost no
    -- matter how chatty the hook is.
    local ENEMY_REFRESH_INTERVAL = 0.2
    -- v0.16.3: how often one AI's health component is asked whether it is dead, from
    -- inside the game's own corpse check on that AI.
    local CORPSE_READ_INTERVAL = 2.0
    -- v0.18.26 flying enemies. The hunt is over and the answer is the same one the
    -- breakable walls gave: THERE IS NO PER-MOVEMENT HOOK for a creature with no feet.
    -- Everything the class chain offers has now been tried against a real run --
    -- PlayFootstepVFX and OnFootDown/HandleFootDown need feet; PlayFoleyLoop,
    -- UpdateFoleyParams and OnUpdateFoleyParams are silent or per-frame (v0.18.25 cut
    -- all three); the aggro pair is one-shot. The last candidate, OnFoleyLinearVelocity-
    -- ChangeExceedThreshold, fires on ACCELERATION rather than movement, so a bat gliding
    -- at a steady speed never trips it. Her 143004 run and the video she recorded agree
    -- exactly: BP_Batman_C got 3 velocity events all session against 17 for a crab, and
    -- on screen the dot sits still while the bat circles and only jumps when it dives at
    -- her -- because the dive is the only hard acceleration a bat ever produces.
    --
    -- So the marker is looked at again instead, the same shape as the wall re-check that
    -- has worked all day, and bounded on every side:
    --   * arithmetic first -- a tick with nothing stale and near costs a table walk;
    --   * a range gate, because a frozen dot only misleads where you can see the thing;
    --   * a staleness gate, so anything the hooks already refresh is never polled;
    --   * a hard per-tick budget with a resuming cursor, so the cost cannot scale with
    --     the number of enemies in the room (the v0.18.14 lesson: a termination PROOF,
    --     not a termination hope);
    --   * it stops entirely when no enemy is tracked.
    local ENEMY_POLL_MS = 500
    local ENEMY_POLL_RANGE_SQ = 5000.0 * 5000.0 -- 50 m
    local ENEMY_POLL_STALE_SECONDS = 0.75
    local ENEMY_POLL_BUDGET = 4
    -- Declared HERE, above note_enemy, which calls it. A local referenced above its
    -- declaration compiles to a nil global and dies only when that line runs
    -- (invariant 0c -- this project has paid for it four times).
    local schedule_enemy_poll

    local function enemies_enabled()
        return Config.ShowLocalInteractables ~= false
            and (Config.LocalShowEnemy ~= false or Config.LocalShowBoss ~= false)
    end

    -- v0.11.2: off by default. Dots now come from spawn, so a living enemy that has
    -- simply not done anything recently must keep its marker; decay would delete it.
    -- Set EnemyDecaySeconds in the ini to re-enable the sweep.
    local function enemy_decay_seconds()
        local value = tonumber(Config.EnemyDecaySeconds) or 0.0
        if value <= 0.0 then return 0.0 end
        return math.max(2.0, math.min(120.0, value))
    end

    local function retire_enemy(owner_key, reason)
        local record = runtime.records[owner_key]
        if record == nil or record.enemy ~= true then return false end
        runtime.enemy_count = math.max(0, runtime.enemy_count - 1)
        -- v0.18.26: the wrapper dies with the record that justified holding it.
        runtime.enemy_actors[owner_key] = nil
        return retire_owner(owner_key, reason)
    end

    local sweep_enemies
    local function arm_enemy_sweep()
        if enemy_decay_seconds() <= 0.0 then return end
        if runtime.enemy_sweep_armed or runtime.enemy_count <= 0 then return end
        runtime.enemy_sweep_armed = true
        local generation = runtime.world_generation
        WorkBudget.Schedule(2000, function()
            runtime.enemy_sweep_armed = false
            if generation ~= runtime.world_generation then return end
            sweep_enemies()
        end, "discovery.enemy-sweep")
    end

    -- Primitive-only: compares stored timestamps, never touches a game object.
    sweep_enemies = function()
        local cutoff = os.clock() - enemy_decay_seconds()
        local stale = nil
        for owner_key, record in pairs(runtime.records) do
            if record.enemy == true and (tonumber(record.seen_at) or 0) < cutoff then
                stale = stale or {}
                stale[#stale + 1] = owner_key
            end
        end
        if stale ~= nil then
            for _, owner_key in ipairs(stale) do
                runtime.metrics.enemy_decayed = runtime.metrics.enemy_decayed + 1
                retire_enemy(owner_key, "local-enemy-decayed")
            end
        end
        arm_enemy_sweep()
    end

    -- "boss" from the AI's own class name.
    --
    -- v0.11.2 read actor.HealthComponent here and then reflected on the component to
    -- look for "Boss" in its class. That is a second object's class resolved from
    -- inside a hook on a spawning or mid-behaviour AI, it is the most speculative read
    -- in the layer, and it sits in the same UE4SS reflection path the 2026-09-12 crash
    -- faulted in. The class name we already have costs nothing and cannot fault, so
    -- the health component is not touched at all. Bosses whose class name does not say
    -- so will read as ordinary enemies until there is evidence for a safer signal.
    -- v0.12.1: BP_AICharacter_C is the base of the friendly cast too. Her hub capture
    -- admitted BP_NPC_FrogChild_C, BP_NPC_Vlas_Hub_C, BP_NPC_Shopkeeper_Dog_C and the
    -- hub pillow cultists as enemies -- the red dots behind the NPC icons. The
    -- classifier owns the friend/foe list; this asks it before admitting anything.
    local function enemy_hint(class_name)
        class_name = tostring(class_name or "")
        if type(Classifier.IsFriendly) == "function" and Classifier.IsFriendly(class_name) then
            return nil
        end
        if string.find(class_name, "Boss", 1, true) ~= nil then return "boss" end
        return "enemy"
    end

    -- v0.16.3. Read inside the AI's own CheckCorpseRemoval callback, so the actor is
    -- alive and executing; the component is its HealthComponent (the variable the
    -- DeathEvent bound-event name carries). IsDeadOrDying() covers the pre-death and
    -- death-started states that a corpse that never despawns sits in. nil = could not
    -- read; the caller counts it and leaves the record alone.
    local function enemy_dead_or_dying(actor)
        local health = Object.Unwrap(Object.Property(actor, "HealthComponent"))
        if not Object.Valid(health) then return nil end
        local ok, dead = pcall(function() return health:IsDeadOrDying() end)
        if ok and type(dead) == "boolean" then return dead end
        ok, dead = pcall(function() return health:GetDeathState() end)
        local numeric = ok and tonumber(Object.Unwrap(dead)) or nil
        -- ESpartaDeathState: 0 is NotDead.
        if numeric ~= nil then return numeric ~= 0 end
        return nil
    end

    local function note_corpse_check(actor, label)
        runtime.metrics.corpse_checks = runtime.metrics.corpse_checks + 1
        local owner_key = Object.Address(actor)
        local record = owner_key ~= nil and runtime.records[owner_key] or nil
        if record == nil or record.enemy ~= true then return end
        local now = os.clock()
        local last = tonumber(record.corpse_checked_at)
        if last ~= nil and now - last < CORPSE_READ_INTERVAL then return end
        record.corpse_checked_at = now
        runtime.metrics.corpse_reads = runtime.metrics.corpse_reads + 1
        local dead = enemy_dead_or_dying(actor)
        trace(label, "corpse-read", "dead=" .. tostring(dead))
        if dead == true then
            runtime.metrics.corpse_dead = runtime.metrics.corpse_dead + 1
            runtime.metrics.enemy_deaths = runtime.metrics.enemy_deaths + 1
            retire_enemy(owner_key, "local-enemy-corpse")
        elseif dead == nil then
            runtime.metrics.corpse_read_failures = runtime.metrics.corpse_read_failures + 1
        end
    end

    local function note_enemy(actor, label)
        runtime.metrics.enemy_events = runtime.metrics.enemy_events + 1
        label = tostring(label or "ai.enemy")
        if not enemies_enabled() then
            runtime.metrics.enemy_skipped = runtime.metrics.enemy_skipped + 1
            return
        end
        trace(label, "enemy-enter")
        actor = Object.Unwrap(actor)
        if not Object.Valid(actor) then
            runtime.metrics.invalid_contexts = runtime.metrics.invalid_contexts + 1
            return
        end
        local owner_key = Object.Address(actor)
        if owner_key == nil then return end
        -- v0.16.9: the foley / foot natives are SpartaCharacter's, the player's parent
        -- as much as the AI's. The player is never an enemy dot. Address compare only.
        --
        -- v0.18.25: AND IT FAILED OPEN. `state.player` is set to nil by
        -- DropWorldReferencesUnread on every world change and stays nil until the pawn is
        -- re-resolved a moment later, so for that window this test was simply skipped. It
        -- cost nothing while nothing we hooked fired for the player; v0.18.24 armed six
        -- natives on SpartaCharacter -- the player's own class -- and she loaded in to a
        -- red enemy dot sitting on her own arrow, beside the beacon. Her 133801 log names
        -- it outright:
        --
        --   enemyRefresh class=BP_PlayerCharacter_C total=10 by=ai.OnUpdateFoleyParams:10
        --
        -- (with enemySelfSkipped=2888, so the address test works perfectly once there IS
        -- an address -- the defect is entirely the window where there is not.)
        --
        -- "I do not know who the player is" must mean "admit nobody who might be her", not
        -- "admit everybody". So the class name is checked as well as the address: the
        -- address test stays because it is exact and covers any pawn class, and the name
        -- test covers the window where the address is unavailable. A player character is
        -- never an enemy under any circumstance, which makes this belt and braces rather
        -- than a fallback.
        if state.player ~= nil and owner_key == Object.Address(state.player) then
            runtime.metrics.enemy_self_skipped = (runtime.metrics.enemy_self_skipped or 0) + 1
            return
        end
        local actor_class = Object.ClassShortName(actor)
        if type(actor_class) == "string" and actor_class:find("PlayerCharacter", 1, true) then
            runtime.metrics.enemy_self_skipped = (runtime.metrics.enemy_self_skipped or 0) + 1
            runtime.metrics.enemy_self_by_class = (runtime.metrics.enemy_self_by_class or 0) + 1
            return
        end
        trace(label, "enemy-live", "id=" .. tostring(owner_key))
        local record = runtime.records[owner_key]
        if record ~= nil and record.enemy ~= true then
            -- An NPC or interactable already owns this address; leave it alone.
            return
        end
        if record == nil then
            -- v0.11.7: breadcrumbs now bracket every native call in this function, not
            -- just follow it. The 12:49 crash died between `enemy-live` and the next
            -- line, which narrowed it to "one of the two reflection calls below" and no
            -- further; a pre-call line names the call itself.
            trace(label, "enemy-classify")
            local class_name = Object.ClassShortName(actor)
            trace(label, "enemy-class", "class=" .. tostring(class_name))
            local hint = enemy_hint(class_name)
            if hint == nil then
                runtime.metrics.enemy_friendly_skipped =
                    runtime.metrics.enemy_friendly_skipped + 1
                trace(label, "enemy-friendly", "class=" .. tostring(class_name))
                return
            end
            record = upsert(source_key("enemy", actor), actor, label, hint)
            if record == nil then
                trace(label, "enemy-rejected")
                return
            end
            trace(label, "enemy-admitted", string.format(
                "category=%s hidden=%s suppressed=%s pos=(%.0f,%.0f,%.0f)",
                tostring(record.category), tostring(record.hidden == true),
                tostring(record.suppressed == true),
                tonumber(record.x) or 0, tonumber(record.y) or 0, tonumber(record.z) or 0))
            record.enemy = true
            record.seen_at = os.clock()
            -- Deliberately NOT set to seen_at: the first refresh after admission has to
            -- get through the throttle, because the BeginPlay position is the one most
            -- likely to be wrong (see PostSpawnMovement above).
            record.refreshed_at = nil
            runtime.enemy_count = runtime.enemy_count + 1
            runtime.metrics.enemy_admitted = runtime.metrics.enemy_admitted + 1
            if record.category == "Boss" then
                runtime.metrics.boss_admitted = runtime.metrics.boss_admitted + 1
            end
            -- v0.18.26: the hook already handed us the actor, so the poll never has to
            -- look one up (StaticFindObject measured 8-16 ms; that is the whole reason
            -- the wall re-check resolves once per approach). A retained wrapper, and
            -- invariant 0's actual requirement applies: it is validated on every single
            -- use, dropped on retirement, on a failed validate and on world reset, and
            -- counted honestly in retainedActorRefs rather than claimed to be zero.
            runtime.enemy_actors[owner_key] = actor
            arm_enemy_sweep()
            schedule_enemy_poll()
            return
        end
        -- Known enemy: refresh position from the live object and keep it alive.
        local now = os.clock()
        record.seen_at = now
        -- Throttled against the last position read, not against the last event, or a
        -- hook firing faster than the interval would starve the refresh entirely.
        -- A nil timestamp means "never refreshed since admission" and is exempt: os.clock()
        -- is small early in a process, so treating nil as 0 would have throttled the one
        -- refresh that matters most.
        local last_refresh = tonumber(record.refreshed_at)
        if last_refresh ~= nil and now - last_refresh < ENEMY_REFRESH_INTERVAL then
            runtime.metrics.enemy_refresh_throttled =
                runtime.metrics.enemy_refresh_throttled + 1
            return
        end
        record.refreshed_at = now
        -- v0.18.26: keep the cached wrapper current. The engine can hand back a fresh
        -- wrapper for the same actor, and this path already has a validated one.
        runtime.enemy_actors[owner_key] = actor
        trace(label, "enemy-locate")
        local pos = location(actor)
        trace(label, "enemy-refresh", pos ~= nil and string.format(
            "pos=(%.0f,%.0f,%.0f)", pos.x or 0, pos.y or 0, pos.z or 0) or "pos=none")
        runtime.metrics.enemy_refreshed = runtime.metrics.enemy_refreshed + 1
        -- v0.18.22 (user, 2026-09-15: "one of the issues we had with enemy tracking was
        -- with flying enemies"). Her 130041 run admitted BP_Batman_C three times and
        -- BP_StoneCrab_C five times, so admission is not the problem. The suspicion is the
        -- REFRESH: an enemy's marker follows it through movement hooks, and the busiest by
        -- far is ai.PlayFootstepVFX -- which a bat, having no feet on the ground, would
        -- never call. If that is right, a flying enemy's dot sits at its spawn point until
        -- it touches the player (ai.PushPlayer) or aggros.
        --
        -- Counted per class AND per source rather than guessed at, because the last time I
        -- reasoned my way to "this hook must fire" I was wrong for four versions
        -- (invariant 0j). One table increment on a path that already reads a location:
        -- a class with admissions but no footstep refreshes is the answer, in one dump.
        local class_name = tostring(record.class or "?")
        local by_class = runtime.enemy_refresh_by_class[class_name]
        if by_class == nil then
            by_class = { total = 0 }
            runtime.enemy_refresh_by_class[class_name] = by_class
        end
        by_class.total = by_class.total + 1
        local source = tostring(label or "?")
        by_class[source] = (by_class[source] or 0) + 1
        if pos == nil then return end
        local moved_x = (tonumber(record.x) or pos.x) - pos.x
        local moved_y = (tonumber(record.y) or pos.y) - pos.y
        record.x, record.y, record.z = pos.x, pos.y, pos.z
        if type(ctx.LocalPool) == "table" and type(ctx.LocalPool.UpdateRecordPosition) == "function" then
            ctx.LocalPool.UpdateRecordPosition(record)
        end
        state.local_overlay_refresh_requested = true
        if moved_x * moved_x + moved_y * moved_y >= ENEMY_MOVE_RESYNC_SQ then
            request_sync("local-enemy-moved")
        end
    end

    -- Traps and shootable props -----------------------------------------------
    -- Same discipline as the enemy layer: the actor is read inside the live callback
    -- and only primitives are kept. A trap is admitted with an explicit hint, so the
    -- classifier never has to guess from a name it has never seen.
    local function note_trap_like(actor, hint, label)
        trace(label, "trap-enter", "hint=" .. tostring(hint))
        actor = Object.Unwrap(actor)
        if not Object.Valid(actor) then
            runtime.metrics.invalid_contexts = runtime.metrics.invalid_contexts + 1
            return nil
        end
        if Config.ShowLocalInteractables == false then return nil end
        local owner_key = Object.Address(actor)
        if owner_key == nil then return nil end
        local existing = runtime.records[owner_key]
        if existing ~= nil then
            -- Already known: refresh the position, since a rearmed trap is the same
            -- actor and a shootable prop can be knocked about.
            local pos = location(actor)
            if pos ~= nil then
                existing.x, existing.y, existing.z = pos.x, pos.y, pos.z
                if type(ctx.LocalPool) == "table"
                    and type(ctx.LocalPool.UpdateRecordPosition) == "function" then
                    ctx.LocalPool.UpdateRecordPosition(existing)
                end
                state.local_overlay_refresh_requested = true
            end
            return existing
        end
        trace(label, "trap-upsert")
        local record = upsert(source_key(hint, actor), actor, label, hint)
        if record == nil then
            trace(label, "trap-rejected")
            return nil
        end
        trace(label, "trap-admitted", "category=" .. tostring(record.category))
        -- v0.18.1: this family has no EndPlay we can hook (neither the base class nor
        -- the lock-on component defines one), so a level that streams out and back
        -- in leaves the old record behind and admits the new actor beside it -- her
        -- 15:48 snapshot had two BP_EnShooting_Ritual_Poison_C records with the same
        -- UAID name at the same spot and different addresses. An actor's name is
        -- unique within its level, so a new admission with a name a different record
        -- already carries supersedes that record. One pass over the records, at
        -- admission only (a few hundred per session); no reflection.
        if type(record.name) == "string" and record.name ~= "<unnamed>" then
            for other_key, other in pairs(runtime.records) do
                if other_key ~= owner_key and other.name == record.name
                    and other.class == record.class and other.enemy ~= true then
                    runtime.metrics.env_superseded = runtime.metrics.env_superseded + 1
                    retire_owner(other_key, "local-env-superseded")
                end
            end
        end
        if record.category == "Trap" then
            runtime.metrics.trap_admitted = runtime.metrics.trap_admitted + 1
        else
            runtime.metrics.shootable_admitted = runtime.metrics.shootable_admitted + 1
        end
        return record
    end

    -- v0.18.1: the env-shooting family's hint from its class name. Bear traps and
    -- barrels have their own LOCAL toggles; everything else is a shootable prop.
    local function env_shooting_hint(class_name)
        class_name = tostring(class_name or "")
        if string.find(class_name, "BearTrap", 1, true) ~= nil
            or string.find(class_name, "Bear_Trap", 1, true) ~= nil then
            return "trap"
        elseif string.find(class_name, "ExplosiveBarrel", 1, true) ~= nil then
            return "barrel" -- v0.16.9: its own LOCAL toggle
        end
        return "shootable"
    end

    -- Hidden and breakable walls (v0.16.0) ------------------------------------
    -- Same discipline as traps: the actor is read inside a live callback or a seed
    -- slice and only primitives are kept. Three sources feed one `note_wall`:
    --   1. the per-world seed -- FindAllOf per wall class, one class per WorkBudget
    --      slice, once at world-ready. Not a recurring scan: it runs again only when
    --      the engine says a wall was constructed (3), and never faster than the floor.
    --   2. ReceiveBeginPlay on the two variants that override it.
    --   3. NotifyOnNewObject on the two families, which fires when a streamed level
    --      constructs a wall the seed ran too early to see. The callback never touches
    --      the object (it is mid-construction); it schedules a re-seed instead, so the
    --      only object reads stay in the seed, on actors FindAllOf just handed back.
    -- Open state: DisableCollision is hooked, and because the save path calls it at
    -- load -- before any seed -- for walls already opened, the seed also reads the
    -- WallCollision mesh's collision flag. That read is unproven until a run says so
    -- (invariant 0b/0c); a failed read counts as unknown and the wall shows as unopened,
    -- which is the honest default. An open wall has no marker at all (v0.16.1, user
    -- decision): the seed skips it and the open signal retires it.
    -- v0.16.6: generalised from the wall read -- true when the named component's
    -- collision is off, false when on, nil when it cannot be read.
    local function collision_off(actor, component_name)
        if component_name == nil then return nil end
        local collision = Object.Unwrap(Object.Property(actor, component_name))
        if not Object.Valid(collision) then return nil end
        local ok, enabled = pcall(function() return collision:IsCollisionEnabled() end)
        if ok and type(enabled) == "boolean" then return not enabled end
        ok, enabled = pcall(function() return collision:GetCollisionEnabled() end)
        local numeric = ok and tonumber(Object.Unwrap(enabled)) or nil
        -- ECollisionEnabled::NoCollision is 0.
        if numeric ~= nil then return numeric == 0 end
        return nil
    end

    -- v0.18.8: PROVEN by her 095813 run, the first watch that straddled a break. A
    -- BP_DestructiblePlaceholderWall_C keeps 25 components while it stands. Breaking it
    -- DESTROYS exactly three of them, and changes nothing else -- not one actor flag, not
    -- one of the other 22 components:
    --
    --     Mesh               StaticMeshComponent  (P_Placeholder_Wall_Collider, collision=1)
    --     TargetingCollision SphereComponent      (the lock-on target)
    --     AdditionalProps    ChildActorComponent  (the visible planks)
    --
    -- The Chaos GeometryCollection, the FieldSystem and BlockingVolume all survive
    -- untouched, which is why every earlier guess about collision switching off was
    -- wrong. The intact wall is destroyed and the debris takes over.
    --
    -- So the read is: the solid mesh is gone. Two components are required to agree rather
    -- than one, because a single unreadable property must never retire a marker -- a
    -- false "broken" hides a wall the player has not opened yet, which is worse than a
    -- stale icon. Anything short of both gone answers nil, not false.
    local RUBBLE_WALL_GONE = { "Mesh", "TargetingCollision" }

    -- Object.Property answers (nil, nil) for a property that is simply ABSENT, which
    -- looks identical to one whose object was destroyed. Conflating those would retire
    -- the marker on any wall that never had a Mesh at all -- a false "broken" hides a
    -- wall the player has not opened yet, which is worse than a stale icon. So: a nil
    -- value is UNREADABLE, and only a value that exists and fails Object.Valid is GONE.
    local function named_component_state(actor, key)
        local value, err = Object.Property(actor, key)
        if err ~= nil or value == nil then return "unreadable" end
        return Object.Valid(Object.Unwrap(value)) and "present" or "gone"
    end

    -- The proven path, from her 095813 watch: the component ARRAY. Slower than a named
    -- read and known to work, so it decides only when the named reads cannot.
    local function array_component_state(actor, wanted)
        local value, err = Object.Property(actor, "BlueprintCreatedComponents")
        if err ~= nil or value == nil then return nil end
        local values = Object.ArrayCopy(Object.Unwrap(value))
        if type(values) ~= "table" then return nil end
        local seen = false
        for _, component in ipairs(values) do
            component = Object.Unwrap(component)
            if Object.Valid(component) then
                local name = Object.ShortName(component)
                if name ~= nil and tostring(name):find(wanted, 1, true) == 1 then
                    seen = true
                    break
                end
            end
        end
        -- The array only lists live components, so "not in it" means gone -- but only
        -- worth believing when the array itself read back with something in it.
        if #values == 0 then return nil end
        return seen and "present" or "gone"
    end

    local function is_rubble_wall(actor)
        local name = Object.ShortName(actor)
        return type(name) == "string" and name:find("DestructiblePlaceholder", 1, true) ~= nil
    end

    -- v0.18.12: the ARRAY decides, and the named property is only the fallback. Her 103902
    -- / 103952 pair is why. The re-check ran (secretRecheckLooks climbed 13 -> 36,
    -- secretRecheckMissing=0, so the path lookup works), the marker did come off -- but by
    -- `local-wall-actor-gone`, 57 s after admission, when the GAME finally destroyed the
    -- actor. Not one `wallRecheck wall-broken` trace: the component read never once said
    -- broken. The named property keeps handing back a wrapper that still passes
    -- Object.Valid after the component is destroyed, so `present > 0` held and the wall
    -- read "standing" right up to the end. The BlueprintCreatedComponents array is the
    -- read that was actually proven -- her 095813 watch saw exactly 25 entries become 22
    -- at the break -- because the array lists only live components. So ask it first.
    -- Walking ~25 entries once a second is nothing; being wrong for a minute is not.
    local function rubble_wall_broken(actor)
        actor = Object.Unwrap(actor)
        if not Object.Valid(actor) then return nil, "actor-invalid" end
        local gone, present, unreadable = 0, 0, 0
        local path = "array"
        for _, key in ipairs(RUBBLE_WALL_GONE) do
            local answer = array_component_state(actor, key)
            if answer == nil then
                answer = named_component_state(actor, key)
                path = "named"
            end
            if answer == "present" then present = present + 1
            elseif answer == "gone" then gone = gone + 1
            else unreadable = unreadable + 1 end
        end
        local detail = string.format("path=%s gone=%d present=%d unreadable=%d",
            path, gone, present, unreadable)
        -- One surviving component is enough to say the wall still stands.
        if present > 0 then return false, detail end
        -- Both gone, and both actually read: broken.
        if gone == #RUBBLE_WALL_GONE then return true, detail end
        -- Anything else is a read that could not decide, and decides nothing.
        return nil, detail
    end

    -- The hidden-wall family keeps its own answer: that one really does switch a named
    -- collision component off, and it has the hooks to say so besides.
    local function wall_open_state(actor)
        if is_rubble_wall(actor) then return rubble_wall_broken(actor) end
        return collision_off(actor, "WallCollision")
    end

    local function read_bool(actor, key)
        local value, err = Object.Property(actor, key)
        if err ~= nil or value == nil then return nil end
        if type(value) == "boolean" then return value end
        return Object.AsBoolean(value)
    end

    local function read_int(actor, key)
        local value, err = Object.Property(actor, key)
        if err ~= nil or value == nil then return nil end
        return tonumber(Object.Unwrap(value))
    end

    -- v0.16.6: is this plant spent? Three reads, in order of how directly they say so:
    -- the saved RewardExtracted flag; HitsReceived against RequiredHits; the hit
    -- collision the game turns off. Returns true/false/nil plus the values read, for
    -- the breadcrumb -- a run has to say which of the three carries the answer (0b).
    -- Six reflected reads at most, on a live actor inside a hook or a seed slice.
    local function plant_spent_state(actor, collision_name)
        runtime.metrics.hittable_state_reads = runtime.metrics.hittable_state_reads + 1
        local extracted = read_bool(actor, "RewardExtracted")
        local hits, required = read_int(actor, "HitsReceived"), read_int(actor, "RequiredHits")
        local off = collision_off(actor, collision_name)
        local detail = string.format("extracted=%s hits=%s/%s collisionOff=%s",
            tostring(extracted), tostring(hits), tostring(required), tostring(off))
        if extracted == true then return true, detail end
        if hits ~= nil and required ~= nil and required > 0 and hits >= required then
            return true, detail
        end
        if off == true then return true, detail end
        if extracted == false or hits ~= nil or off == false then return false, detail end
        runtime.metrics.hittable_state_unknown = runtime.metrics.hittable_state_unknown + 1
        return nil, detail
    end

    -- v0.18.1: is this env-shooting object spent? GotActivated is the one-shot's own
    -- flag, saved and restored by the game; an object the player can neither shoot
    -- nor target has no purpose on the map either (AI-only props). Returns
    -- true/false/nil plus the values read, for the breadcrumb: a run has to say which
    -- of the flags carries the answer for a torch (0b). Five reflected reads at most,
    -- on a live actor inside a hook.
    local function env_object_state(actor)
        runtime.metrics.env_state_reads = runtime.metrics.env_state_reads + 1
        local activated = read_bool(actor, "GotActivated")
        local ready = read_bool(actor, "IsReady")
        local shootable = read_bool(actor, "CanPlayerShootIt")
        local targetable = read_bool(actor, "CanPlayerTargetIt")
        local can_target = read_bool(actor, "bCanBeTargeted")
        local detail = string.format("activated=%s ready=%s playerShoot=%s playerTarget=%s canBeTargeted=%s",
            tostring(activated), tostring(ready), tostring(shootable), tostring(targetable),
            tostring(can_target))
        if activated == true then return true, detail, "activated" end
        if shootable == false and targetable == false then return true, detail, "player-cannot-use" end
        if activated == false or shootable ~= nil or targetable ~= nil then return false, detail end
        runtime.metrics.env_state_unknown = runtime.metrics.env_state_unknown + 1
        return nil, detail
    end

    -- Remember an env-shooting object as spent and drop its marker if it has one.
    local function spend_env_object(owner_key, memory, reason)
        runtime.env_spent[owner_key] = memory
        if runtime.records[owner_key] ~= nil then
            runtime.metrics.env_state_retired = runtime.metrics.env_state_retired + 1
            retire_owner(owner_key, reason)
        end
    end

    -- The lock-on component's BeginPlay: the component knows its actor, and the
    -- actor's class decides whether it is a trap or an ordinary shootable prop.
    -- v0.18.1: the object's own state is read first. A torch (or barrel) the game has
    -- already fired -- restored from the save, or fired in this world before the
    -- component began play again -- is skipped, and retired if it was admitted
    -- earlier; one the game reset clears its memory. Bear traps are read for the
    -- breadcrumb only: a sprung trap's own signals (TriggerTrap / DisableTrap /
    -- RearmTrap) already govern it, and GotActivated on an armed trap is unproven.
    local function note_env_shooting(component)
        runtime.metrics.env_shooting_events = runtime.metrics.env_shooting_events + 1
        trace("envShooting.ReceiveBeginPlay", "env-enter")
        local actor = component_owner(component)
        if actor == nil then
            runtime.metrics.invalid_contexts = runtime.metrics.invalid_contexts + 1
            trace("envShooting.ReceiveBeginPlay", "env-no-owner")
            return
        end
        trace("envShooting.ReceiveBeginPlay", "env-owner")
        local class_name = tostring(Object.ClassShortName(actor) or "")
        trace("envShooting.ReceiveBeginPlay", "env-class", "class=" .. class_name)
        local hint = env_shooting_hint(class_name)
        local owner_key = Object.Address(actor)
        local spent, detail, why = env_object_state(actor)
        trace("envShooting.ReceiveBeginPlay", "env-state", "class=" .. class_name .. " " .. tostring(detail))
        if hint ~= "trap" and owner_key ~= nil then
            if spent == true then
                runtime.metrics.env_spent_skipped = runtime.metrics.env_spent_skipped + 1
                spend_env_object(owner_key, "spent-at-beginplay:" .. tostring(why), "local-env-" .. tostring(why))
                trace("envShooting.ReceiveBeginPlay", "env-spent", "class=" .. class_name .. " why=" .. tostring(why))
                return
            elseif spent == nil and runtime.env_spent[owner_key] ~= nil then
                runtime.metrics.env_spent_skipped = runtime.metrics.env_spent_skipped + 1
                trace("envShooting.ReceiveBeginPlay", "env-spent", "class=" .. class_name
                    .. " memory=" .. tostring(runtime.env_spent[owner_key]))
                return
            elseif spent == false and runtime.env_spent[owner_key] ~= nil then
                runtime.metrics.env_reset = runtime.metrics.env_reset + 1
                runtime.env_spent[owner_key] = nil
            end
        end
        note_trap_like(actor, hint, "envshooting.begin")
    end

    -- v0.18.1: an env-shooting object's state changed (a post-hook: the flags are the
    -- values the call produced). Context is the actor. A spent one loses its marker
    -- and is remembered; a fresh one with a spent memory (the game reset it) is
    -- forgotten and, if the lock-on BeginPlay admitted nothing for it, admitted now.
    local function note_env_state(actor, label)
        runtime.metrics.env_state_events = runtime.metrics.env_state_events + 1
        actor = Object.Unwrap(actor)
        if not Object.Valid(actor) then
            runtime.metrics.invalid_contexts = runtime.metrics.invalid_contexts + 1
            return
        end
        local owner_key = Object.Address(actor)
        if owner_key == nil then return end
        local class_name = tostring(Object.ClassShortName(actor) or "")
        local hint = env_shooting_hint(class_name)
        local spent, detail, why = env_object_state(actor)
        trace(label, "env-state", "class=" .. class_name .. " known=" .. tostring(runtime.records[owner_key] ~= nil)
            .. " " .. tostring(detail))
        if hint == "trap" then return end
        if spent == true then
            if runtime.env_spent[owner_key] == nil or runtime.records[owner_key] ~= nil then
                spend_env_object(owner_key, "spent-at-" .. tostring(label) .. ":" .. tostring(why),
                    "local-env-" .. tostring(why))
            end
        elseif spent == false then
            if runtime.env_spent[owner_key] ~= nil then
                runtime.metrics.env_reset = runtime.metrics.env_reset + 1
                runtime.env_spent[owner_key] = nil
            end
            -- A live one nobody admitted yet (its lock-on BeginPlay ran before the
            -- hooks existed) gets its marker here; a known one only refreshes.
            note_trap_like(actor, hint, label)
        end
    end

    -- Remember a plant as spent and drop its marker if it has one.
    local function spend_hittable(owner_key, memory, reason)
        runtime.hittable_done[owner_key] = memory
        runtime.metrics.hittable_state_spent = runtime.metrics.hittable_state_spent + 1
        if runtime.records[owner_key] ~= nil then
            runtime.metrics.hittable_retired = runtime.metrics.hittable_retired + 1
            retire_owner(owner_key, reason)
        end
    end

    local function retire_wall(owner_key, reason)
        local record = owner_key ~= nil and runtime.records[owner_key] or nil
        if record == nil or record.category ~= "Secret" then return false end
        runtime.metrics.secret_retired = runtime.metrics.secret_retired + 1
        return retire_owner(owner_key, reason or "local-wall-opened")
    end

    -- v0.18.11 wall re-check -----------------------------------------------------
    -- Proven exhaustively across six of her bundles: a BP_DestructiblePlaceholderWall_C
    -- announces its break through NOTHING. Its whole class chain declares four functions;
    -- the two that could plausibly be called (BP_VFX_Physical_C:GetHitResponse,
    -- BP_VFX_Breakable_C:GetStoppingDistanceOffset) armed and stayed silent; and in the
    -- 102923 run not one hook of any kind fired in the 25 seconds spanning the break --
    -- the whole hookEvents histogram is byte-identical either side. There is no event.
    --
    -- So it has to be looked at again, and the whole design is about making that cheap:
    --   * The actor is re-acquired by PATH. StaticFindObject is a name lookup; FindAllOf
    --     measured 9.31 ms average / 15 ms max in her run, which at any useful rate is a
    --     dropped frame every tick. No wrapper is retained (invariant 0) -- only a string.
    --   * The tick is arithmetic first. Player position is already cached in state, so a
    --     tick with no wall nearby costs a table walk and a subtraction, and touches
    --     nothing native at all.
    --   * It only runs while this world has a rubble wall admitted. The job stops when
    --     the last one is retired, and does not exist in a world without any.
    local WALL_RECHECK_MS = 1000
    local WALL_RECHECK_RANGE_SQ = 3000.0 * 3000.0 -- 30 m; the marker is only visible near

    local schedule_wall_recheck

    local function wall_recheck_tick(epoch)
        -- v0.18.27: same epoch guard as the enemy poll. This tick had the identical
        -- latent flaw -- a world reset clears `pending` while a queued job survives --
        -- and only escaped notice because no rubble wall was tracked when it was caught.
        if epoch ~= runtime.tick_epoch then return end
        runtime.wall_recheck_pending = false
        if global_runtime.generation ~= instance_generation then return end
        if runtime.quarantined then schedule_wall_recheck() return end
        local px, py = tonumber(state.player_world_x), tonumber(state.player_world_y)
        local tracked, looked = 0, 0
        for owner_key, record in pairs(runtime.records) do
            if record.recheck_path ~= nil and runtime.secret_open[owner_key] == nil then
                tracked = tracked + 1
                local near = px == nil or py == nil
                if not near then
                    local dx, dy = record.x - px, record.y - py
                    near = (dx * dx + dy * dy) <= WALL_RECHECK_RANGE_SQ
                end
                -- Out of range is where the wrapper is dropped, so nothing is held while
                -- the player is anywhere else in the world.
                if not near then runtime.wall_actors[owner_key] = nil end
                if near then
                    looked = looked + 1
                    -- v0.18.13: resolve ONCE per approach, not once per tick. Her 104750
                    -- run measured native.staticfind at 8.2-10.67 ms average, 11 ms max --
                    -- StaticFindObject is not the cheap name hash I assumed when I chose
                    -- it over FindAllOf; it is the same price. At 1 Hz that is a dropped
                    -- frame every second while standing at a breakable wall, which is a
                    -- performance regression I introduced and would have shipped.
                    --
                    -- So the resolved wrapper is held for as long as the player stays in
                    -- range. That IS a retained actor reference and this file's summary no
                    -- longer claims otherwise. It is bounded on every side: only wall
                    -- records, only while within range, dropped the moment the player
                    -- leaves or the wrapper stops validating, cleared by the world reset,
                    -- and every single use goes through Object.Valid (invariant 0's actual
                    -- requirement). The path stays as the recovery route, so losing the
                    -- wrapper costs one re-resolve rather than the fix.
                    local actor = Object.Unwrap(runtime.wall_actors[owner_key])
                    if not Object.Valid(actor) then
                        local token = Perf.Begin()
                        local ok, found = pcall(StaticFindObject, record.recheck_path)
                        Perf.End("native.staticfind", token)
                        actor = ok and Object.Unwrap(found) or nil
                        runtime.metrics.secret_recheck_resolves =
                            runtime.metrics.secret_recheck_resolves + 1
                        runtime.wall_actors[owner_key] = Object.Valid(actor) and actor or nil
                    end
                    runtime.metrics.secret_recheck_looks =
                        runtime.metrics.secret_recheck_looks + 1
                    if Object.Valid(actor) then
                        runtime.metrics.secret_state_reads =
                            runtime.metrics.secret_state_reads + 1
                        local broken, detail = rubble_wall_broken(actor)
                        if broken == true then
                            runtime.metrics.secret_state_open =
                                runtime.metrics.secret_state_open + 1
                            runtime.secret_open[owner_key] = "wall-broken"
                            runtime.wall_actors[owner_key] = nil
                            trace("wallRecheck", "wall-broken", detail)
                            retire_wall(owner_key, "local-wall-broken")
                        elseif broken == nil then
                            runtime.metrics.secret_state_unknown =
                                runtime.metrics.secret_state_unknown + 1
                        end
                    else
                        -- The actor itself is gone: the wall left with its level.
                        runtime.metrics.secret_recheck_missing =
                            runtime.metrics.secret_recheck_missing + 1
                        runtime.wall_actors[owner_key] = nil
                        runtime.secret_open[owner_key] = "wall-actor-gone"
                        retire_wall(owner_key, "local-wall-actor-gone")
                    end
                end
            end
        end
        if tracked > 0 then schedule_wall_recheck() end
    end

    schedule_wall_recheck = function()
        if runtime.wall_recheck_pending then return end
        if type(WorkBudget) ~= "table" or type(WorkBudget.Schedule) ~= "function" then return end
        runtime.wall_recheck_pending = true
        local epoch = runtime.tick_epoch
        WorkBudget.Schedule(WALL_RECHECK_MS, function()
            wall_recheck_tick(epoch)
        end, "discovery.wall-recheck")
    end

    -- v0.18.26 enemy marker poll. For flying enemies, which announce their movement
    -- through nothing -- see the note beside ENEMY_POLL_MS for the full list of hooks
    -- tried and why each one cannot work for a creature with no feet.
    --
    -- Everything cheap happens before anything native. The record already carries the
    -- last known position as plain numbers, so range is arithmetic on a table we are
    -- walking anyway; staleness is a clock comparison; and only what survives both gates
    -- costs an ActorLocation read. The budget and cursor mean a room full of enemies
    -- costs exactly the same per tick as one enemy, just spread over more ticks.
    local function enemy_poll_tick(epoch)
        -- Checked BEFORE `pending` is cleared: a superseded tick must leave the flag
        -- exactly as it found it, or it would hand a second chain permission to exist.
        if epoch ~= runtime.tick_epoch then return end
        runtime.enemy_poll_pending = false
        if global_runtime.generation ~= instance_generation then return end
        if runtime.quarantined then schedule_enemy_poll() return end
        local px, py = tonumber(state.player_world_x), tonumber(state.player_world_y)
        local now = os.clock()
        local tracked, looked, moved = 0, 0, 0
        -- Ordered keys, so the cursor means the same thing between ticks: pairs() order
        -- is not stable across insertions and a cursor into it would skip records.
        local keys = {}
        for owner_key, record in pairs(runtime.records) do
            if record.enemy == true and runtime.enemy_actors[owner_key] ~= nil then
                keys[#keys + 1] = owner_key
            end
        end
        tracked = #keys
        if tracked == 0 then return end
        table.sort(keys)
        local start = 1
        if runtime.enemy_poll_cursor ~= nil then
            for index = 1, tracked do
                if keys[index] >= runtime.enemy_poll_cursor then start = index break end
            end
        end
        local spent = 0
        for step = 0, tracked - 1 do
            if spent >= ENEMY_POLL_BUDGET then break end
            local index = ((start - 1 + step) % tracked) + 1
            local owner_key = keys[index]
            local record = runtime.records[owner_key]
            if record ~= nil and record.enemy == true then
                -- Anything a hook refreshed recently is already correct; polling it would
                -- be pure waste and would spend the budget the flyers need.
                local last = tonumber(record.refreshed_at)
                local stale = last == nil or (now - last) >= ENEMY_POLL_STALE_SECONDS
                local near = px == nil or py == nil
                if not near and stale then
                    local dx, dy = (tonumber(record.x) or 0) - px, (tonumber(record.y) or 0) - py
                    near = (dx * dx + dy * dy) <= ENEMY_POLL_RANGE_SQ
                end
                if stale and near then
                    spent = spent + 1
                    runtime.enemy_poll_cursor = keys[(index % tracked) + 1]
                    local actor = Object.Unwrap(runtime.enemy_actors[owner_key])
                    if not Object.Valid(actor) then
                        -- Gone. The endplay hooks normally retire it first; this is the
                        -- backstop, and dropping the wrapper is the point either way.
                        runtime.enemy_actors[owner_key] = nil
                        runtime.metrics.enemy_poll_missing =
                            runtime.metrics.enemy_poll_missing + 1
                    else
                        looked = looked + 1
                        runtime.metrics.enemy_poll_reads =
                            runtime.metrics.enemy_poll_reads + 1
                        local pos = location(actor)
                        if pos ~= nil then
                            record.refreshed_at = now
                            local moved_x = (tonumber(record.x) or pos.x) - pos.x
                            local moved_y = (tonumber(record.y) or pos.y) - pos.y
                            record.x, record.y, record.z = pos.x, pos.y, pos.z
                            if type(ctx.LocalPool) == "table"
                                and type(ctx.LocalPool.UpdateRecordPosition) == "function" then
                                ctx.LocalPool.UpdateRecordPosition(record)
                            end
                            state.local_overlay_refresh_requested = true
                            if moved_x * moved_x + moved_y * moved_y >= ENEMY_MOVE_RESYNC_SQ then
                                moved = moved + 1
                                request_sync("local-enemy-polled")
                            end
                            -- Counted per class beside the hook-driven refreshes, so the
                            -- summary shows at a glance which classes only move because
                            -- of this -- which is the whole flying-enemy question.
                            local class_name = tostring(record.class or "?")
                            local by_class = runtime.enemy_refresh_by_class[class_name]
                            if by_class == nil then
                                by_class = { total = 0 }
                                runtime.enemy_refresh_by_class[class_name] = by_class
                            end
                            by_class.total = by_class.total + 1
                            by_class["poll"] = (by_class["poll"] or 0) + 1
                        end
                    end
                end
            end
        end
        if looked > 0 or moved > 0 then
            trace("enemyPoll", "polled", string.format("tracked=%d looked=%d moved=%d",
                tracked, looked, moved))
        end
        -- Only while something is tracked. A world with no enemies admitted has no tick.
        if tracked > 0 then schedule_enemy_poll() end
    end

    schedule_enemy_poll = function()
        if runtime.enemy_poll_pending then return end
        if type(WorkBudget) ~= "table" or type(WorkBudget.Schedule) ~= "function" then return end
        runtime.enemy_poll_pending = true
        local epoch = runtime.tick_epoch
        WorkBudget.Schedule(ENEMY_POLL_MS, function()
            enemy_poll_tick(epoch)
        end, "discovery.enemy-poll")
    end

    local function note_wall(actor, label)
        trace(label, "wall-enter")
        actor = Object.Unwrap(actor)
        if not Object.Valid(actor) then
            runtime.metrics.invalid_contexts = runtime.metrics.invalid_contexts + 1
            return nil, "actor-invalid"
        end
        if Config.ShowLocalInteractables == false then return nil, "layer-off" end
        local owner_key = Object.Address(actor)
        if owner_key == nil then return nil, "identity-unavailable" end
        -- FindAllOf may hand back the class default object; it is not in the world.
        local short_name = Object.ShortName(actor)
        if type(short_name) == "string" and short_name:sub(1, 9) == "Default__" then
            return nil, "class-default"
        end
        local pos = location(actor)
        if pos == nil then
            runtime.metrics.invalid_contexts = runtime.metrics.invalid_contexts + 1
            return nil, "location-unavailable"
        end
        -- A streamed actor FindAllOf caught before its transform was serialised sits
        -- at the origin. Leave it for the follow-up re-seed rather than pin it there.
        if pos.x == 0 and pos.y == 0 and (pos.z or 0) == 0 then
            runtime.metrics.secret_location_pending = runtime.metrics.secret_location_pending + 1
            trace(label, "wall-pending")
            return nil, "location-pending"
        end
        -- Already open, by an open signal that beat this seed: no marker.
        if runtime.secret_open[owner_key] ~= nil then
            retire_wall(owner_key, "local-" .. tostring(runtime.secret_open[owner_key]))
            trace(label, "wall-open", "source=signal")
            return nil, "open"
        end
        local existing = runtime.records[owner_key]
        if existing ~= nil then
            existing.x, existing.y, existing.z = pos.x, pos.y, pos.z
            if type(ctx.LocalPool) == "table"
                and type(ctx.LocalPool.UpdateRecordPosition) == "function" then
                ctx.LocalPool.UpdateRecordPosition(existing)
            end
            state.local_overlay_refresh_requested = true
            return existing
        end
        -- First sight of this wall: ask the collision mesh whether the game already
        -- opened it (the save path at load runs before any seed).
        runtime.metrics.secret_state_reads = runtime.metrics.secret_state_reads + 1
        local open = wall_open_state(actor)
        if open == true then
            runtime.metrics.secret_state_open = runtime.metrics.secret_state_open + 1
            -- Remembered, so later seeds in this world skip it without another read.
            runtime.secret_open[owner_key] = "wall-open-at-seed"
            trace(label, "wall-open", "source=collision")
            return nil, "open"
        elseif open == nil then
            runtime.metrics.secret_state_unknown = runtime.metrics.secret_state_unknown + 1
        end
        trace(label, "wall-upsert")
        local record = upsert(source_key("wall", actor), actor, label, "secret")
        if record == nil then
            trace(label, "wall-rejected")
            return nil, "rejected"
        end
        runtime.metrics.secret_admitted = runtime.metrics.secret_admitted + 1
        -- v0.18.11: a Chaos breakable announces nothing, ever (proven exhaustively -- see
        -- WALL_RECHECK below), so the only way to notice it broke is to look again. The
        -- actor's PATH is remembered, as a string, so the look-up later costs a name hash
        -- instead of a 10 ms FindAllOf and no wrapper is retained (invariant 0).
        if is_rubble_wall(actor) then
            record.recheck_path = Object.FullPath(actor)
            runtime.metrics.secret_recheck_tracked =
                runtime.metrics.secret_recheck_tracked + (record.recheck_path ~= nil and 1 or 0)
            schedule_wall_recheck()
        end
        trace(label, "wall-admitted", string.format("category=%s state=%s pos=(%.0f,%.0f,%.0f) path=%s",
            tostring(record.category), open == false and "standing" or "unknown",
            tonumber(record.x) or 0, tonumber(record.y) or 0, tonumber(record.z) or 0,
            tostring(record.recheck_path ~= nil)))
        return record
    end

    -- v0.16.5: a hittable met by the seed or by its own BeginPlay (the flower chest;
    -- v0.16.6 the attack flower too). Spent ones are skipped by the memory the hooks
    -- fill; the class default object is skipped by name; and (v0.16.6) the plant's own
    -- state is read, so one the game already spent -- at load, before any hook could
    -- exist -- is skipped, or retired if the lock-on BeginPlay admitted it first.
    local function note_hittable(actor, label, collision_name)
        actor = Object.Unwrap(actor)
        if not Object.Valid(actor) then
            runtime.metrics.invalid_contexts = runtime.metrics.invalid_contexts + 1
            return nil, "actor-invalid"
        end
        local owner_key = Object.Address(actor)
        if owner_key == nil then return nil, "identity-unavailable" end
        if runtime.hittable_done[owner_key] ~= nil then
            runtime.metrics.hittable_skipped = runtime.metrics.hittable_skipped + 1
            trace(label, "hittable-spent", "reason=" .. tostring(runtime.hittable_done[owner_key]))
            return nil, "spent"
        end
        local short_name = Object.ShortName(actor)
        if type(short_name) == "string" and short_name:sub(1, 9) == "Default__" then
            return nil, "class-default"
        end
        local spent, detail = plant_spent_state(actor, collision_name)
        trace(label, "hittable-state", detail)
        if spent == true then
            spend_hittable(owner_key, "spent-at-" .. tostring(label), "local-plant-spent")
            return nil, "spent"
        end
        local existed = runtime.records[owner_key] ~= nil
        local record = note_trap_like(actor, "shootable", label)
        if record ~= nil and not existed then
            runtime.metrics.hittable_admitted = runtime.metrics.hittable_admitted + 1
        end
        return record, record == nil and "rejected" or nil
    end

    -- v0.18.20: the answer to "is this class worth a 9.3 ms scan", asked BEFORE the scan.
    -- Both switches are the ones the overlay already honours: the master local-layer
    -- switch, and the per-category switch the settings row writes (LocalShow<Category>).
    -- A category that is off draws nothing, so enumerating it buys nothing either.
    local function seed_entry_enabled(entry)
        if Config.ShowLocalInteractables == false then return false end
        local category = entry ~= nil and entry.category or nil
        if category == nil then return true end
        return Config["LocalShow" .. tostring(category)] ~= false
    end

    -- True when at least one seed class is worth enumerating; the notify path asks this
    -- before it schedules anything at all. `classes` is an ARRAY of class names (what a
    -- notify spec carries) or nil for "any of them".
    local function any_seed_entry_enabled(classes)
        local wanted = nil
        if classes ~= nil then
            wanted = {}
            for _, class_name in ipairs(classes) do wanted[class_name] = true end
        end
        for _, entry in ipairs(WALL_SEED_CLASSES) do
            if seed_entry_enabled(entry)
                and (wanted == nil or wanted[entry.class] == true) then
                return true
            end
        end
        return false
    end

    local function seed_wall_class(entry, reason)
        if type(FindAllOf) ~= "function" then return 0, 0, 0 end
        -- v0.18.33: FindAllOf is the same global scan the arm probes do, so it waits for
        -- the same quiet. A skipped slice is re-seeded by the next construction notify.
        if not churn_quiet("wall-seed") then
            runtime.metrics.secret_seed_deferred = (runtime.metrics.secret_seed_deferred or 0) + 1
            return 0, 0, 0
        end
        -- Checked here as well as at the scheduling site, because a player can turn the
        -- switch off in the 150 ms between one slice and the next.
        if not seed_entry_enabled(entry) then
            runtime.metrics.secret_seed_skipped = runtime.metrics.secret_seed_skipped + 1
            return 0, 0, 0
        end
        local class_name = entry.class
        local token = Perf.Begin()
        local ok, found = pcall(FindAllOf, class_name)
        Perf.End("native.findall", token)
        if not ok or type(found) ~= "table" then return 0, 0, 0 end
        local admitted, pending = 0, 0
        for _, value in ipairs(found) do
            local record, why
            if entry.kind == "hittable" then
                record, why = note_hittable(value, "seed." .. tostring(class_name), entry.collision)
            else
                record, why = note_wall(value, "wallSeed." .. tostring(class_name))
            end
            if record ~= nil then admitted = admitted + 1
            elseif why == "location-pending" then pending = pending + 1 end
        end
        return #found, admitted, pending
    end

    local schedule_wall_reseed
    local walls_armed -- assigned below Arm(); declared here so the re-seed closure binds the local
    -- One class per scheduled slice, WALL_SEED_SLICE_MS apart, so a world load pays
    -- five short FindAllOf calls spread over most of a second rather than one lump.
    -- `classes`, when given, is a set of class names: the families this seed is actually
    -- about. nil means all of them (a world-ready or late-arm seed, which has no notify
    -- to narrow it). Entries whose switch is off are dropped here, so they never even
    -- take a scheduler slot.
    -- v0.18.20: what each class's switch said the last time we looked. ApplyLiveSetting
    -- compares against it so that turning a category back ON seeds immediately instead of
    -- waiting for the next world load -- and so that the dozen other local-presentation
    -- rows (icon sizes, colors, ranges) never cost a scan.
    local function snapshot_seed_enabled()
        local snapshot = {}
        for _, entry in ipairs(WALL_SEED_CLASSES) do
            snapshot[entry.class] = seed_entry_enabled(entry)
        end
        runtime.seed_enabled_was = snapshot
    end

    local function seed_walls(reason, allow_followup, classes)
        local generation = runtime.world_generation
        snapshot_seed_enabled()
        local planned = {}
        for _, entry in ipairs(WALL_SEED_CLASSES) do
            if classes == nil or classes[entry.class] == true then
                if seed_entry_enabled(entry) then
                    planned[#planned + 1] = entry
                else
                    -- v0.18.21: counted HERE. v0.18.20 put the counter inside
                    -- seed_wall_class, which a filtered class never reaches, so her 124344
                    -- run reported secretSeedSkipped=0 while the gate was demonstrably
                    -- working (the seed lines read classes=2, not classes=7). A metric
                    -- that cannot move is worse than no metric: it reads as "the fix did
                    -- nothing". Count where the thing actually gets skipped.
                    runtime.metrics.secret_seed_skipped =
                        runtime.metrics.secret_seed_skipped + 1
                end
            end
        end
        if #planned == 0 then
            runtime.metrics.secret_seeds_skipped = runtime.metrics.secret_seeds_skipped + 1
            return
        end
        runtime.metrics.secret_seeds = runtime.metrics.secret_seeds + 1
        local totals = { found = 0, admitted = 0, pending = 0, cpu = 0.0, classes = 0 }
        local started_records = count_records()
        for index, entry in ipairs(planned) do
            WorkBudget.Schedule((index - 1) * WALL_SEED_SLICE_MS, function()
                if generation ~= runtime.world_generation or runtime.quarantined then return end
                local started = os.clock()
                local token = Perf.Begin()
                local found, admitted, pending = seed_wall_class(entry, reason)
                Perf.End("discovery.wall-seed", token)
                totals.found = totals.found + found
                totals.admitted = totals.admitted + admitted
                totals.pending = totals.pending + pending
                totals.cpu = totals.cpu + (os.clock() - started) * 1000.0
                totals.classes = totals.classes + 1
                if totals.classes == #planned then
                    runtime.metrics.secret_seed_candidates =
                        runtime.metrics.secret_seed_candidates + totals.found
                    runtime.metrics.secret_seed_cpu_ms = runtime.metrics.secret_seed_cpu_ms + totals.cpu
                    runtime.secret_reseed_at = os.clock()
                    log(string.format(
                        "Local discovery seed reason=%s classes=%d found=%d admitted=%d pending=%d records=%d->%d cpuMs=%.3f recurring=false",
                        tostring(reason), totals.classes, totals.found, totals.admitted,
                        totals.pending, started_records, count_records(), totals.cpu))
                    if totals.admitted > 0 then request_sync("local-wall-seed") end
                    -- Something was still at the origin: one more pass, on the floor, and
                    -- only one -- a follow-up never schedules a follow-up, so an object
                    -- that lives at the origin cannot turn this into a recurring scan.
                    -- v0.18.20: the follow-up inherits THIS seed's scope. Re-scheduling it
                    -- unscoped would have quietly undone the scoping -- one pending flower
                    -- chest would have dragged all five wall classes back through a scan.
                    if totals.pending > 0 and allow_followup ~= false then
                        local again = nil
                        if classes ~= nil then
                            again = {}
                            for _, planned_entry in ipairs(planned) do
                                again[#again + 1] = planned_entry.class
                            end
                        end
                        schedule_wall_reseed("pending", false, again)
                    end
                end
            end, "discovery.wall-seed")
        end
    end

    -- Coalesced: at most one pending re-seed per world, never sooner than the floor
    -- after the previous seed finished. A burst of constructions during a level
    -- stream costs one re-seed.
    --
    -- v0.18.20, two changes.
    --
    -- (a) The pending re-seed ACCUMULATES its class set instead of dropping the second
    -- caller. With scoped re-seeds (each notify asks only about its own family), the old
    -- "already pending, return false" would have silently lost the second family: a
    -- hidden-wall notify followed by a rubble-wall notify would have seeded only hidden
    -- walls, and the rubble wall would have waited for the next seed. A dropped caller
    -- was harmless when every re-seed did everything; it is a bug the moment they differ.
    -- `classes == nil` means "all of them" and swallows any narrower set already pending.
    --
    -- (b) The floor is much longer once arming is complete -- see
    -- WALL_RESEED_ARMED_FLOOR_SECONDS.
    schedule_wall_reseed = function(reason, allow_followup, classes)
        if classes == nil then
            runtime.reseed_classes = nil
            runtime.reseed_all_pending = true
        elseif not runtime.reseed_all_pending then
            local set = runtime.reseed_classes or {}
            for _, class_name in ipairs(classes) do set[class_name] = true end
            runtime.reseed_classes = set
        end
        if runtime.secret_reseed_pending then return false end
        local delay = WALL_RESEED_DELAY_MS
        if runtime.secret_reseed_at ~= nil then
            local since = (os.clock() - runtime.secret_reseed_at) * 1000.0
            local floor_seconds = walls_armed() and WALL_RESEED_ARMED_FLOOR_SECONDS
                or WALL_RESEED_FLOOR_SECONDS
            local floor_ms = floor_seconds * 1000.0
            if since < floor_ms then delay = math.max(delay, math.floor(floor_ms - since + 0.5)) end
        end
        runtime.secret_reseed_pending = true
        local generation = runtime.world_generation
        WorkBudget.Schedule(delay, function()
            runtime.secret_reseed_pending = false
            local planned = runtime.reseed_classes
            runtime.reseed_classes, runtime.reseed_all_pending = nil, false
            if generation ~= runtime.world_generation or runtime.quarantined then return end
            -- v0.16.3: a construction means the class is loaded now, so this is the
            -- moment to arm the hooks that were pending on it -- no need to wait for
            -- the timed ladder.
            if not walls_armed() then runtime.arm_cursor = 1 runtime.Arm() end
            runtime.metrics.secret_reseeds = runtime.metrics.secret_reseeds + 1
            seed_walls(reason, allow_followup, planned)
        end, "discovery.wall-reseed")
        return true
    end

    -- The NotifyOnNewObject callback. Mid-construction object: not read, not kept.
    local function note_wall_construction(spec)
        if global_runtime.generation ~= instance_generation then return end
        runtime.metrics.secret_notify_events = runtime.metrics.secret_notify_events + 1
        trace(spec.label, "notify")
        if runtime.quarantined then return end -- the world-ready seed covers a load
        -- v0.18.20: nothing below here is worth doing for a family the player has
        -- switched off -- not the absent-cache clear (which buys another round of 12 ms
        -- class probes), and not the re-seed. The registration itself stays: it is
        -- one-time, walls_armed() counts it, and a callback that returns here costs a
        -- table lookup.
        if not any_seed_entry_enabled(spec.classes) then
            runtime.metrics.secret_notify_skipped = runtime.metrics.secret_notify_skipped + 1
            return
        end
        -- v0.18.17: a construction is the ONLY evidence that a class this world did not
        -- have might now exist, so it is what clears the absent cache -- and it clears it
        -- at most a few times per world, because a streaming area can fire these
        -- constantly and each clear costs another round of 12 ms probes.
        if runtime.class_absent_clears < WALL_ABSENT_CLEAR_LIMIT then
            runtime.class_absent_clears = runtime.class_absent_clears + 1
            runtime.class_absent = {}
        end
        -- v0.18.20: only this family. A rubble wall being built says nothing about
        -- flower chests, and re-seeding all seven classes on one notify was six 9.3 ms
        -- scans of pure waste for every section that streamed in.
        schedule_wall_reseed("notify:" .. tostring(spec.label), true, spec.classes)
    end

    -- v0.18.20: a category switched back on has to seed now. Without this the gate that
    -- saves the scans would also mean "turn hidden walls off and on again and they are
    -- gone until you change area", which is a worse bug than the one being fixed.
    function runtime.ApplyLiveSetting(setting)
        if type(setting) ~= "table" or setting.apply ~= "local-presentation" then return end
        local was = runtime.seed_enabled_was
        if was == nil then snapshot_seed_enabled() return end
        local newly = nil
        for _, entry in ipairs(WALL_SEED_CLASSES) do
            if seed_entry_enabled(entry) and was[entry.class] == false then
                newly = newly or {}
                newly[#newly + 1] = entry.class
            end
        end
        snapshot_seed_enabled()
        if newly ~= nil then
            schedule_wall_reseed("setting-enabled", true, newly)
        end
    end

    local function note_event(spec, context)
        if global_runtime.generation ~= instance_generation then return end
        runtime.metrics.hook_events = runtime.metrics.hook_events + 1
        local label = tostring(spec.label or "?")
        runtime.label_events[label] = (runtime.label_events[label] or 0) + 1
        -- v0.11.7: the governor runs before anything touches `context`, so a per-frame
        -- hook costs two table increments and a clock read. It is deliberately ahead of
        -- the quarantine check and every kind branch: the whole point is that no code
        -- downstream needs to know whether its hook turned out to be hot.
        if not governor_admits(label, spec.refresh == true) then
            runtime.metrics.governor_rejected = runtime.metrics.governor_rejected + 1
            return
        end
        -- One coarse line for the kinds that have no phase trace of their own, so the
        -- log always names the last hook that ran before a crash, not just the last
        -- v0.11.2 hook.
        -- v0.18.33: an actor arrived or left, so the object array is moving. Two
        -- statements, only on the lifecycle kinds.
        if CHURN_KINDS[spec.kind] then runtime.last_churn_clock = governor_clock() end
        if spec.kind ~= "enemy-seen" and spec.kind ~= "enemy-dead"
            and spec.kind ~= "trap-begin" and spec.kind ~= "env-shooting-begin"
            and spec.kind ~= "probe" and spec.kind ~= "secret-begin"
            and spec.kind ~= "corpse-check" and spec.kind ~= "hittable-begin"
            and spec.kind ~= "hittable-hit" and spec.kind ~= "hittable-regrow"
            and spec.kind ~= "env-state" then
            trace(label, "hook")
        end
        -- v0.10.10: removals are processed during LoadMap quarantine too. Begin
        -- events were always accepted there, so dropping the matching end events
        -- left records for actors the load itself spawned and destroyed.
        if runtime.quarantined then
            runtime.metrics.quarantined_events = runtime.metrics.quarantined_events + 1
        end
        if spec.kind == "handler-lifecycle-begin" then
            runtime.metrics.handler_lifecycle_begin = runtime.metrics.handler_lifecycle_begin + 1
            capture_handler(context, spec.label, "handler-lifecycle")
        elseif spec.kind == "handler-lifecycle-end" then
            runtime.metrics.handler_lifecycle_end = runtime.metrics.handler_lifecycle_end + 1
            local lifecycle_key = source_key("handler-lifecycle", context)
            local register_key = source_key("handler-register", context)
            local ended_addr = Object.Address(context)
            if ended_addr ~= nil then
                runtime.handler_disabled[ended_addr] = nil
                local ended_record = record_for_handler(ended_addr)
                if ended_record ~= nil and ended_record.disabled_by ~= nil then
                    ended_record.disabled_by[ended_addr] = nil
                    refresh_suppression(ended_record)
                end
            end
            if lifecycle_key ~= nil then remove_source(lifecycle_key, "local-handler-end") end
            if register_key ~= nil then remove_source(register_key, "local-handler-end") end
        elseif spec.kind == "handler-register" then
            runtime.metrics.handler_register = runtime.metrics.handler_register + 1
            capture_handler(context, spec.label, "handler-register")
        elseif spec.kind == "handler-unregister" then
            runtime.metrics.handler_unregister = runtime.metrics.handler_unregister + 1
            local key = source_key("handler-register", context)
            if key ~= nil then remove_source(key, "local-handler-unregister") end
        elseif spec.kind == "actor-begin" then
            runtime.metrics.actor_begin = runtime.metrics.actor_begin + 1
            capture_actor(context, spec.label)
        elseif spec.kind == "actor-end" then
            runtime.metrics.actor_end = runtime.metrics.actor_end + 1
            local key = source_key("actor", context)
            if key ~= nil then remove_source(key, "local-actor-end") end
        elseif spec.kind == "owner-end" then
            -- Fires for every AI character (enemies included). Address lookup only:
            -- no class, name, or location reflection. An NPC leaving the world
            -- retires its whole record (all sources), dropping any retained ref.
            runtime.metrics.owner_end = runtime.metrics.owner_end + 1
            local owner_key = Object.Address(context)
            local ending = owner_key ~= nil and runtime.records[owner_key] or nil
            if ending ~= nil then
                runtime.metrics.owner_end_retired = runtime.metrics.owner_end_retired + 1
                if ending.enemy == true then
                    retire_enemy(owner_key, "local-enemy-endplay")
                else
                    retire_owner(owner_key, "local-owner-endplay")
                end
            end
        elseif spec.kind == "enemy-seen" then
            if spec.refresh == true and Config.EnemyRefreshHooks == false then
                runtime.metrics.enemy_refresh_disabled =
                    runtime.metrics.enemy_refresh_disabled + 1
            else
                note_enemy(context, label)
            end
        elseif spec.kind == "enemy-dead" then
            runtime.metrics.enemy_deaths = runtime.metrics.enemy_deaths + 1
            trace(label, "enemy-dead")
            local owner_key = Object.Address(context)
            if owner_key ~= nil then retire_enemy(owner_key, "local-enemy-died") end
        elseif spec.kind == "trap-begin" then
            runtime.metrics.trap_state_events = runtime.metrics.trap_state_events + 1
            note_trap_like(context, "trap", spec.label)
        elseif spec.kind == "env-shooting-begin" then
            note_env_shooting(context)
        elseif spec.kind == "env-state" then
            -- v0.18.1: an env-shooting object's flags, read on the function's return.
            note_env_state(context, label)
        elseif spec.kind == "env-retire" then
            -- v0.18.1: InvalidateCollision / Invalidate on an env-shooting object mean
            -- spent by themselves -- remembered by address whether or not a record
            -- exists yet (the restore at load can run before the admitting BeginPlay).
            runtime.metrics.env_retire_events = runtime.metrics.env_retire_events + 1
            trace(label, "env-retire")
            local owner_key = Object.Address(context)
            if owner_key ~= nil then
                local reason = tostring(spec.reason or "env-invalidated")
                spend_env_object(owner_key, reason, "local-" .. reason)
            end
        elseif spec.kind == "corpse-check" then
            -- v0.16.3: the game's periodic corpse check on an AI; ask its health.
            note_corpse_check(context, label)
        elseif spec.kind == "hittable-begin" then
            -- v0.16.4: a hittable's own BeginPlay; context is the actor. v0.16.6: the
            -- same path as the seed, state read included.
            note_hittable(context, label, spec.collision)
        elseif spec.kind == "hittable-hit" then
            -- v0.16.6: a hit, read on the function's return. A plant the hit has just
            -- spent loses its marker here if no spent signal of its own has said so; a
            -- live one nobody admitted yet (hooks armed after the seed) is admitted.
            runtime.metrics.hittable_hits = runtime.metrics.hittable_hits + 1
            local owner_key = Object.Address(context)
            if owner_key ~= nil and runtime.hittable_done[owner_key] == nil then
                local spent, detail = plant_spent_state(context, spec.collision)
                trace(label, "hittable-hit", detail)
                if spent == true then
                    spend_hittable(owner_key, "spent-after-hit", "local-plant-spent")
                elseif runtime.records[owner_key] == nil
                    and note_trap_like(context, "shootable", label) ~= nil then
                    runtime.metrics.hittable_admitted = runtime.metrics.hittable_admitted + 1
                end
            end
        elseif spec.kind == "hittable-regrow" then
            -- v0.16.6: the plant grew back (read on return, so the state is the reset
            -- one). The spent memory is cleared; the plant is re-admitted when its state
            -- reads fresh, and left alone -- memory still clear, so the next read decides
            -- -- when it does not.
            runtime.metrics.hittable_regrown = runtime.metrics.hittable_regrown + 1
            local owner_key = Object.Address(context)
            if owner_key ~= nil then
                runtime.hittable_done[owner_key] = nil
                local spent, detail = plant_spent_state(context, spec.collision)
                trace(label, "hittable-regrow", detail)
                if spent ~= true and runtime.records[owner_key] == nil
                    and note_trap_like(context, "shootable", label) ~= nil then
                    runtime.metrics.hittable_admitted = runtime.metrics.hittable_admitted + 1
                end
            end
        elseif spec.kind == "hittable-retire" then
            -- v0.16.4: spent, dropped, collected or untargetable -- remembered by address
            -- whether or not a record exists yet.
            local owner_key = Object.Address(context)
            if owner_key ~= nil then
                local reason = tostring(spec.reason or "hittable-spent")
                runtime.hittable_done[owner_key] = reason
                if runtime.records[owner_key] ~= nil then
                    runtime.metrics.hittable_retired = runtime.metrics.hittable_retired + 1
                    retire_owner(owner_key, "local-" .. reason)
                end
            end
        elseif spec.kind == "probe" then
            -- Counted per label and nothing else, until the evidence says what it is.
            runtime.metrics.probe_events = runtime.metrics.probe_events + 1
            trace(label, "probe")
        elseif spec.kind == "handler-invalidate" then
            -- v0.11.2: Invalidate is the "this is spent" signal, but only for things
            -- you consume. The 2026-09-12 run caught a collected BP_Old_Artifact_Rare_C
            -- sitting on the map with invalidated=1, while the same event fires for a
            -- lift, an end-dungeon lock and the dog shopkeeper, which all have to keep
            -- their icons -- so it retires by category and stays evidence-only for
            -- everything else.
            runtime.metrics.handler_invalidate = runtime.metrics.handler_invalidate + 1
            local handler_addr = Object.Address(context)
            local record = record_for_handler(handler_addr)
            note_state(spec.kind, record and record.class or nil)
            if record ~= nil then
                record.invalidate_count = (tonumber(record.invalidate_count) or 0) + 1
                -- v0.17.0: the loot plants and map fragments that used to be Pickups and
                -- Others are consumed the same way.
                if record.category == "Pickup" or record.category == "Chest"
                    or record.category == "Loot" or record.category == "MapFragment" then
                    local owner_key = runtime.sources["handler-lifecycle:" .. handler_addr]
                        or runtime.sources["handler-register:" .. handler_addr]
                    if owner_key ~= nil then
                        runtime.metrics.invalidate_retired =
                            runtime.metrics.invalidate_retired + 1
                        retire_owner(owner_key, "local-invalidated-collected")
                    end
                end
            end
        elseif spec.kind == "handler-disable" or spec.kind == "handler-enable" then
            -- Address + source-map lookup only. No reflection on the handler.
            local metric = spec.kind == "handler-disable" and "handler_disable" or "handler_enable"
            runtime.metrics[metric] = runtime.metrics[metric] + 1
            local handler_addr = Object.Address(context)
            if handler_addr ~= nil then
                local record = record_for_handler(handler_addr)
                note_state(spec.kind, record and record.class or nil)
                if spec.kind == "handler-enable" then
                    runtime.handler_disabled[handler_addr] = nil
                    if record ~= nil then record.disabled_by[handler_addr] = nil end
                else
                    local why = "disable"
                    runtime.handler_disabled[handler_addr] = why
                    if record ~= nil then record.disabled_by[handler_addr] = why end
                end
                if record ~= nil then refresh_suppression(record) end
            end
        elseif spec.kind == "handler-lock" or spec.kind == "handler-unlock" then
            -- Evidence only: counted per owner class, never gates the marker yet.
            local metric = spec.kind == "handler-lock" and "handler_lock" or "handler_unlock"
            runtime.metrics[metric] = runtime.metrics[metric] + 1
            local record = record_for_handler(Object.Address(context))
            note_state(spec.kind, record and record.class or nil)
        elseif spec.kind == "owner-retire" then
            -- Chest opened / pickup collected: context is the owning actor itself.
            runtime.metrics.owner_retire = runtime.metrics.owner_retire + 1
            local owner_key = Object.Address(context)
            if owner_key ~= nil and runtime.records[owner_key] ~= nil then
                runtime.metrics.owner_retire_retired = runtime.metrics.owner_retire_retired + 1
                retire_owner(owner_key, "local-" .. tostring(spec.reason or "owner-retire"))
            end
        elseif spec.kind == "secret-begin" then
            -- v0.16.0: a wall variant's own BeginPlay; context is the wall actor.
            runtime.metrics.secret_begin_events = runtime.metrics.secret_begin_events + 1
            note_wall(context, spec.label)
        elseif spec.kind == "secret-open" then
            -- v0.16.0: the wall has opened (or, at load, was already open). Remembered
            -- by address whether or not a record exists yet; the seed consults it.
            runtime.metrics.secret_open_events = runtime.metrics.secret_open_events + 1
            local owner_key = Object.Address(context)
            if owner_key ~= nil then
                local reason = tostring(spec.reason or "wall-opened")
                runtime.secret_open[owner_key] = reason
                retire_wall(owner_key, "local-" .. reason)
            end
        -- v0.18.19: the "secret-state" kind is gone with the eight specs that used it.
        -- It existed to read the wall's components at the cheapest moment -- inside a
        -- hook that was already firing for that actor -- and not one of those hooks ever
        -- fired. The same read now happens on the 1 Hz re-check instead, which is the
        -- only thing that has ever noticed one of these walls break.
        end
    end

    local function post_hook_noop() end

    local function callback(spec)
        local section = "hook." .. tostring(spec.label)
        return function(context)
            local token = Perf.Begin()
            local ok, err = pcall(note_event, spec, context)
            Perf.End(section, token)
            if not ok then log("Local discovery callback error source=" .. tostring(spec.label) .. " error=" .. tostring(err)) end
        end
    end

    -- v0.16.3: a RegisterHook on a class the game has not loaded costs ~9 ms to fail
    -- (her 18:37 run: 114 ms per Arm() with twelve pending). One StaticFindObject per
    -- class path per Arm() call answers "is it loaded yet" for every hook on that
    -- class, so a pending class costs one lookup instead of one per function.
    -- v0.18.14: Arm() was the single most expensive thing this mod did, and it did it
    -- twice per area load. Her 105745 run measured native.findobject at 11.67 ms average
    -- over 12 lookups in ONE call -- which is exactly the 169 ms
    -- schedule.discovery.wall-arm-retry and the 161 ms schedule.discovery.wall-reseed in
    -- the same window. Two stalls of a sixth of a second each, on top of a load.
    --
    -- Two changes, both of which only became obvious once StaticFindObject's real cost was
    -- known (v0.18.13: it is ~10 ms, not the cheap hash it was assumed to be):
    --
    --   * A class that is loaded STAYS loaded for the life of the world, so a positive
    --     answer is cached across Arm() calls and the world reset clears it. A class that
    --     is absent may load later, so a negative is never cached -- that is what the
    --     retry ladder is for. After the first pass most classes are present, so the
    --     second and later Arm() calls look up only what is still missing.
    --   * One Arm() call spends at most ARM_LOOKUP_BUDGET lookups. If it runs out with
    --     work left it schedules a continuation, so a cold first pass becomes a handful of
    --     ~20 ms steps rather than one 140 ms freeze. Nothing is skipped; it just arrives
    --     over a few frames instead of all in one.

    local function class_loaded_checker(budget)
        if type(StaticFindObject) ~= "function" then
            return function() return true end, function() return false end
        end
        local spent, exhausted = 0, false
        local function check(path)
            local class_path = string.match(path, "^(.-):[^:]*$") or path
            if runtime.class_present[class_path] then return true end
            -- v0.18.17: NEGATIVES ARE CACHED TOO. v0.18.16 only cached positives, so every
            -- pass spent its whole budget re-asking about the same classes that are not in
            -- this world -- and a pass starts on every construction notify. Her 113354 run
            -- still showed 121 continuations and 253 lookups at ~12 ms each, three seconds
            -- of CPU spent re-learning the same answer. A class that is absent stays absent
            -- until something says otherwise, and the only thing that says otherwise is a
            -- construction notify, which clears these.
            if runtime.class_absent[class_path] then return false end
            if runtime.metrics.arm_lookups >= ARM_PROBE_CEILING then return false end
            if spent >= budget then
                exhausted = true
                return false, "budget"
            end
            spent = spent + 1
            local token = Perf.Begin()
            local ok, found = pcall(StaticFindObject, class_path)
            Perf.End("native.findobject", token)
            runtime.metrics.arm_lookups = runtime.metrics.arm_lookups + 1
            local present = (ok and Object.Valid(found)) and true or false
            if present then runtime.class_present[class_path] = true
            else runtime.class_absent[class_path] = true end
            return present
        end
        return check, function() return exhausted end
    end

    function runtime.Arm(budget)
        if type(RegisterHook) ~= "function" then return 0, #HOOK_SPECS end
        -- v0.18.33: arming probes classes by SCANNING the global object array, and an
        -- array entry mid-teardown is what faults inside UE4SS. Wait for the churn to
        -- stop. A deferral reschedules rather than dropping the pass, so nothing is lost
        -- -- arming is a startup cost, not a deadline.
        if not churn_quiet("arm") then
            if not runtime.arm_continue_pending
                and type(WorkBudget) == "table" and type(WorkBudget.Schedule) == "function" then
                runtime.arm_continue_pending = true
                local generation = runtime.world_generation
                WorkBudget.Schedule(ARM_CONTINUE_MS, function()
                    runtime.arm_continue_pending = false
                    if generation ~= runtime.world_generation or runtime.quarantined then return end
                    runtime.Arm(budget)
                end, "discovery.arm-continue")
            end
            return 0, #HOOK_SPECS
        end
        local armed = 0
        local class_loaded, out_of_budget = class_loaded_checker(
            math.max(1, math.floor(tonumber(budget) or ARM_LOOKUP_BUDGET)))
        -- v0.18.16: a pass walks the spec list ONCE, resuming where the budget ran out.
        -- v0.18.15 had no cursor, so every continuation restarted from the top, always
        -- found the same unloadable classes, always ran out of budget, and always
        -- scheduled another one. Her 111912 run: schedule.discovery.arm-continue at
        -- 6324 ms of an 8352 ms window -- 57 calls, 110.95 ms each, 5.7 per second,
        -- busyPct=83.34. That is the 20 FPS. A perpetual loop I shipped while fixing a
        -- stall, which is the worst possible trade.
        -- An explicit budget means "do a full pass now" -- it is what a caller asks for
        -- when it needs the answer immediately -- so it starts at the top rather than
        -- resuming a partial pass and silently leaving the earlier specs behind.
        -- v0.18.17: and it also reopens the absent cache, because "I need the answer now"
        -- and "trust what we learned earlier" are contradictory instructions. The per-world
        -- probe ceiling still bounds what that can cost.
        if budget ~= nil then runtime.class_absent = {} end
        local resume_at = (budget ~= nil) and 1 or (runtime.arm_cursor or 1)
        local stopped_at = nil
        local started = os.clock()
        for index = resume_at, #HOOK_SPECS do
            local spec = HOOK_SPECS[index]
            if out_of_budget() then stopped_at = index break end
            -- v0.18.22: and stop on TIME too. `index > resume_at` guarantees at least one
            -- spec per pass, so the cursor always advances and the chain always ends --
            -- the thing v0.18.14 got wrong. An explicit budget ("I need the answer now")
            -- still pays whatever it costs rather than returning a half-armed answer.
            if budget == nil and index > resume_at
                and (os.clock() - started) * 1000.0 >= ARM_TIME_SLICE_MS then
                runtime.metrics.arm_time_slices = runtime.metrics.arm_time_slices + 1
                stopped_at = index
                break
            end
            -- The lookup can be REFUSED for budget rather than answered, and a refusal
            -- must not be mistaken for "class not loaded" -- that would mark the spec
            -- pending and, worse, step past it so the pass never came back to it.
            local loaded, refused = true, nil
            if runtime.hooks[spec.path] == nil then loaded, refused = class_loaded(spec.path) end
            if refused == "budget" then stopped_at = index break end
            if runtime.hooks[spec.path] == nil and not loaded then
                local text = "class not loaded"
                if runtime.hook_failures[spec.path] ~= text then
                    runtime.hook_failures[spec.path] = text
                    log(string.format("Local discovery hook label=%s state=pending error=%s",
                        spec.label, text))
                end
            elseif runtime.hooks[spec.path] == nil then
                local ok, pre_id, post_id
                if spec.post == true then
                    -- v0.16.6: a post-hook -- UE4SS runs the third argument after the
                    -- function returns, with the same context. The pre-callback is a
                    -- no-op so the state a hit or a regrow produced is what gets read.
                    ok, pre_id, post_id = pcall(RegisterHook, spec.path, post_hook_noop, callback(spec))
                else
                    ok, pre_id, post_id = pcall(RegisterHook, spec.path, callback(spec))
                end
                if ok then
                    runtime.hooks[spec.path] = { pre = pre_id, post = post_id, label = spec.label }
                    runtime.hook_failures[spec.path] = nil
                    log(string.format("Local discovery hook label=%s state=armed pre=%s post=%s",
                        spec.label, tostring(pre_id), tostring(post_id)))
                else
                    local text = tostring(pre_id)
                    -- v0.18.23: UE4SS distinguishes two failures that this layer used to
                    -- treat identically, and only one of them is temporary. "class not
                    -- loaded" is patience -- the class may stream in later. "no UFunction
                    -- with the specified name was found" is PERMANENT: a name that is
                    -- absent now is absent for ever, so the spec is a defect, not a
                    -- pending registration. Eight of them sat in the pending list from
                    -- v0.16.9 to v0.18.22 looking exactly like patience, and the feature
                    -- they were added to fix silently did nothing the whole time.
                    if text:find("no UFunction with the specified name", 1, true) then
                        runtime.dead_hooks[spec.label] = spec.path
                    end
                    if runtime.hook_failures[spec.path] ~= text then
                        runtime.hook_failures[spec.path] = text
                        log(string.format("Local discovery hook label=%s state=pending error=%s",
                            spec.label, text))
                    end
                end
            end
            if runtime.hooks[spec.path] ~= nil then armed = armed + 1 end
        end
        -- v0.16.0: construction notifications for the wall families, retried exactly
        -- like the hooks (UE4SS resolves the class at registration, so a class the game
        -- has not loaded yet is a pending registration, not a permanent failure).
        if type(NotifyOnNewObject) == "function" then
            for _, spec in ipairs(WALL_NOTIFY_SPECS) do
                if runtime.notify[spec.path] == nil then
                    local ok, err = pcall(NotifyOnNewObject, spec.path, function()
                        local token = Perf.Begin()
                        local ok_note, note_err = pcall(note_wall_construction, spec)
                        Perf.End("notify." .. tostring(spec.label), token)
                        if not ok_note then
                            log("Local discovery notify error source=" .. tostring(spec.label)
                                .. " error=" .. tostring(note_err))
                        end
                    end)
                    if ok then
                        runtime.notify[spec.path] = true
                        runtime.notify_failures[spec.path] = nil
                        log(string.format("Local discovery notify label=%s state=armed", spec.label))
                    else
                        local text = tostring(err)
                        if runtime.notify_failures[spec.path] ~= text then
                            runtime.notify_failures[spec.path] = text
                            log(string.format("Local discovery notify label=%s state=pending error=%s",
                                spec.label, text))
                        end
                    end
                end
            end
        end
        -- The pass either finished the list or stopped mid-way with budget spent. Only
        -- the second case earns a continuation, and it resumes rather than restarting --
        -- so a pass costs at most one lookup per distinct class and then ENDS. Retrying
        -- later is the four-step ladder's job, which is bounded by construction.
        runtime.arm_cursor = stopped_at
        -- v0.18.16: the wall seed owes itself to the moment the wall hooks BECOME armed,
        -- and with a budgeted pass that moment can land in a ladder step, a continuation
        -- or a direct call. So it is decided here, once, by the transition itself rather
        -- than by whichever caller happened to be holding the baton.
        -- Only when the LADDER is what is arming them: that is the "we armed after the
        -- world-ready seed already ran, so seed again" case the ladder was built for. An
        -- ordinary first arm at startup is followed by the world-ready seed anyway.
        if walls_armed ~= nil and runtime.secret_arm_retry_armed then
            local now_armed = walls_armed()
            if now_armed and not runtime.walls_were_armed then
                runtime.walls_were_armed = true
                seed_walls("late-arm", true)
            elseif not now_armed then
                runtime.walls_were_armed = false
            end
        end
        if stopped_at ~= nil and not runtime.arm_continue_pending
            and type(WorkBudget) == "table" and type(WorkBudget.Schedule) == "function" then
            runtime.arm_continue_pending = true
            local generation = runtime.world_generation
            WorkBudget.Schedule(ARM_CONTINUE_MS, function()
                runtime.arm_continue_pending = false
                if generation ~= runtime.world_generation or runtime.quarantined then return end
                runtime.Arm()
            end, "discovery.arm-continue")
        end
        return armed, #HOOK_SPECS
    end

    -- True once every wall hook and both notifications are registered.
    walls_armed = function()
        for _, spec in ipairs(HOOK_SPECS) do
            if (spec.kind == "secret-begin" or spec.kind == "secret-open"
                or spec.kind == "hittable-begin" or spec.kind == "hittable-retire"
                or spec.kind == "hittable-hit" or spec.kind == "hittable-regrow")
                and runtime.hooks[spec.path] == nil then return false end
        end
        if type(NotifyOnNewObject) == "function" then
            for _, spec in ipairs(WALL_NOTIFY_SPECS) do
                if runtime.notify[spec.path] == nil then return false end
            end
        end
        return true
    end

    -- A session that meets its first wall class mid-world: Arm() again on a short
    -- ladder, and seed as soon as the arming lands. Stops the moment it is armed, and
    -- is never re-armed once it has succeeded, so a session with no walls at all pays
    -- four cheap Arm() calls per world and nothing else.
    local function arm_walls_late(generation)
        if runtime.secret_arm_retry_armed or walls_armed() then return end
        runtime.secret_arm_retry_armed = true
        for _, delay_ms in ipairs(WALL_ARM_RETRY_MS) do
            WorkBudget.Schedule(delay_ms, function()
                if generation ~= runtime.world_generation or runtime.quarantined then return end
                if walls_armed() then return end
                -- A ladder step is the bounded "has it loaded yet?" retry, so it is the
                -- other thing allowed to reopen the absent cache -- four steps, and the
                -- per-world probe ceiling above bounds the total either way. Without this
                -- a class that loads with no construction notify would never be armed.
                runtime.class_absent = {}
                runtime.arm_cursor = 1
                runtime.Arm()
            end, "discovery.wall-arm-retry")
        end
    end

    local function bootstrap_targeted()
        if runtime.bootstrap_done or runtime.quarantined or type(FindAllOf) ~= "function" then return end
        runtime.bootstrap_done = true
        runtime.metrics.bootstrap_runs = runtime.metrics.bootstrap_runs + 1
        local started = os.clock()
        local token = Perf.Begin()
        local ok_handlers, handlers = pcall(FindAllOf, "BPC_InteractionHandler_C")
        Perf.End("native.findall", token)
        if ok_handlers and type(handlers) == "table" then
            runtime.metrics.bootstrap_handler_candidates = #handlers
            for _, value in ipairs(handlers) do
                capture_handler(value, "bootstrap:handler", "handler-lifecycle")
            end
        end
        token = Perf.Begin()
        local ok_text, read_text = pcall(FindAllOf, "BP_InteractionReadText_C")
        Perf.End("native.findall", token)
        if ok_text and type(read_text) == "table" then
            runtime.metrics.bootstrap_readtext_candidates = #read_text
            for _, value in ipairs(read_text) do capture_actor(value, "bootstrap:readText") end
        end
        runtime.metrics.bootstrap_cpu_ms = runtime.metrics.bootstrap_cpu_ms
            + (os.clock() - started) * 1000.0
        log(string.format(
            "Local discovery bootstrap reason=hot-attach-only handlers=%d readText=%d admitted=%d cpuMs=%.3f recurring=false",
            runtime.metrics.bootstrap_handler_candidates,
            runtime.metrics.bootstrap_readtext_candidates,
            count_records(), runtime.metrics.bootstrap_cpu_ms))
        request_sync("local-bootstrap")
    end

    function runtime.OnLoadMapPre()
        runtime.quarantined = true
        runtime.saw_load_pre = true
        runtime.world_generation = runtime.world_generation + 1
        runtime.dynamic_token = runtime.dynamic_token + 1
        runtime.sync_token = runtime.sync_token + 1
        runtime.sync_pending = false
        runtime.records = {}
        runtime.sources = {}
        runtime.handler_disabled = {}
        runtime.bootstrap_done = false
        -- v0.11.7: the trace budget resets per world so a crash after a fast travel
        -- still has breadcrumbs, while `retired_labels` deliberately does NOT -- a
        -- UFunction that is called per frame in one world is called per frame in all
        -- of them, and re-arming it would just spend another wasted second.
        runtime.trace_budget = {}
        runtime.trace_window = {}
        runtime.label_window = {}
        -- v0.16.0: the open-wall memory is addresses, so it dies with the world; a
        -- pending re-seed is generation-guarded and simply falls through.
        runtime.secret_open = {}
        -- v0.18.17: both class caches and the probe ceiling are per world.
        runtime.class_present = {}
        runtime.class_absent = {}
        runtime.class_absent_clears = 0
        runtime.arm_cursor = nil
        runtime.walls_were_armed = false
        runtime.arm_continue_pending = false
        runtime.metrics.arm_lookups = 0
        runtime.metrics.arm_time_slices = 0
        runtime.enemy_refresh_by_class = {}
        runtime.wall_actors = {}
        runtime.enemy_actors = {}
        runtime.enemy_poll_pending = false
        runtime.enemy_poll_cursor = nil
        -- v0.18.27: orphan every tick the old world scheduled. Clearing the flags
        -- alone let a surviving job become a second permanent chain.
        runtime.tick_epoch = runtime.tick_epoch + 1
        runtime.wall_recheck_pending = false
        runtime.hittable_done = {}
        runtime.env_spent = {}
        runtime.secret_reseed_pending = false
        runtime.secret_reseed_at = nil
        runtime.secret_arm_retry_armed = false
        -- v0.18.20: the pending re-seed's scope dies with the world that asked for it.
        runtime.reseed_classes = nil
        runtime.reseed_all_pending = false
        runtime.seed_enabled_was = nil
        runtime.metrics.world_resets = runtime.metrics.world_resets + 1
        log(string.format("Local discovery world pre generation=%d registryCleared=true",
            runtime.world_generation))
    end

    function runtime.OnWorldReleased(reason)
        runtime.enemy_count = 0
        runtime.enemy_sweep_armed = false
        runtime.quarantined = false
        runtime.sync_pending = false
        runtime.Arm()
        request_sync("local-world-ready")
        -- v0.16.0: walls have no handler and (mostly) no BeginPlay override, so the
        -- world gets one seed, sliced; a class not yet loaded gets the late ladder.
        seed_walls("world-ready", true)
        if not walls_armed() then arm_walls_late(runtime.world_generation) end
        -- Normal LoadMap flows are already populated by hooks before release.
        -- Only a hot attach into an already-stable world gets one targeted census.
        if not runtime.saw_load_pre and count_records() == 0 then
            local generation = runtime.world_generation
            WorkBudget.Schedule(750, function()
                if generation == runtime.world_generation and not runtime.quarantined
                    and count_records() == 0 then bootstrap_targeted() end
            end, "discovery.census")
        end
        log(string.format(
            "Local discovery world ready generation=%d reason=%s records=%d dynamicTracked=%d lifecycleOnly=%s",
            runtime.world_generation, tostring(reason or "unknown"), count_records(),
            runtime.dynamic_ref_count, tostring(runtime.saw_load_pre)))
    end

    function runtime.Records()
        return runtime.records
    end

    function runtime.Metrics()
        return runtime.metrics
    end

    function runtime.RetireReasons()
        return runtime.retire_reasons
    end

    -- v0.18.13: this used to be the constant 0. It is a count now, because the wall
    -- re-check really does hold a wrapper while the player stands next to a breakable
    -- wall, and a summary that says 0 while something is held is worse than no summary.
    -- Expect 0 everywhere except within 30 m of an unbroken rubble wall.
    -- v0.18.23: a non-zero deadHooks in the summary means a spec names a function that does
    -- not exist, which is always a source bug. Kept beside retained_actor_refs because both
    -- are "numbers the summary must not be allowed to lie about".
    local function dead_hook_count()
        local count = 0
        for _ in pairs(runtime.dead_hooks) do count = count + 1 end
        return count
    end

    local function retained_actor_refs()
        local n = 0
        for _, value in pairs(runtime.wall_actors) do
            if Object.Valid(Object.Unwrap(value)) then n = n + 1 end
        end
        -- v0.18.26: the enemy poll holds wrappers too, and this number has to stay
        -- honest -- v0.18.13 is exactly where it stopped being a constant 0.
        for _, value in pairs(runtime.enemy_actors) do
            if Object.Valid(Object.Unwrap(value)) then n = n + 1 end
        end
        return n
    end

    function runtime.EmitSummary(reason)
        local categories = {}
        for _, key in ipairs(Classifier.Categories()) do categories[key] = 0 end
        local nearest = {}
        local px, py = tonumber(state.player_world_x), tonumber(state.player_world_y)
        for _, record in pairs(runtime.records) do
            categories[record.category] = (categories[record.category] or 0) + 1
            local d2 = math.huge
            if px ~= nil and py ~= nil then
                local dx, dy = record.x - px, record.y - py
                d2 = dx * dx + dy * dy
            end
            nearest[#nearest + 1] = { record = record, d2 = d2 }
        end
        table.sort(nearest, function(a, b) return a.d2 < b.d2 end)
        local category_text = {}
        for _, key in ipairs(Classifier.Categories()) do
            category_text[#category_text + 1] = key .. ":" .. tostring(categories[key] or 0)
        end
        local m = runtime.metrics
        local suppressed_hidden, suppressed_disabled = 0, 0
        for _, record in pairs(runtime.records) do
            if record.hidden == true then suppressed_hidden = suppressed_hidden + 1 end
            if type(record.disabled_by) == "table" and next(record.disabled_by) ~= nil then
                suppressed_disabled = suppressed_disabled + 1
            end
        end
        local reason_names = {}
        for name in pairs(runtime.retire_reasons) do reason_names[#reason_names + 1] = name end
        table.sort(reason_names)
        local reason_parts = {}
        for _, name in ipairs(reason_names) do
            reason_parts[#reason_parts + 1] = name .. ":" .. tostring(runtime.retire_reasons[name])
        end
        local retire_text = #reason_parts > 0 and table.concat(reason_parts, "|") or "none"
        local armed = 0
        for _, spec in ipairs(HOOK_SPECS) do if runtime.hooks[spec.path] ~= nil then armed = armed + 1 end end
        log(string.format(
            "Local discovery summary reason=%s records=%d categories=%s hooks=%d/%d hookEvents=%d admitted=%d filtered=%d handlerInit=%d handlerEnd=%d handlerReg=%d handlerUnreg=%d actorBegin=%d actorEnd=%d ownerEnd=%d ownerEndRetired=%d ownerRetire=%d ownerRetireRetired=%d suppressedHidden=%d suppressedDisabled=%d hiddenAtCapture=%d handlerDisable=%d handlerEnable=%d handlerInvalidate=%d handlerLock=%d handlerUnlock=%d duplicateSources=%d shopHandlers=%d recategorized=%d enemies=%d enemyEvents=%d enemyAdmitted=%d bosses=%d enemyRefreshed=%d enemyRefreshThrottled=%d enemyRefreshDisabled=%d enemySelfSkipped=%d enemyDeaths=%d enemyDecayed=%d enemySkipped=%d enemyFriendlySkipped=%d corpseChecks=%d corpseReads=%d corpseDead=%d corpseReadFailures=%d hittableAdmitted=%d hittableRetired=%d hittableSkipped=%d hittableStateReads=%d hittableSpent=%d hittableUnknown=%d hittableHits=%d hittableRegrown=%d envShootingEvents=%d trapAdmitted=%d shootableAdmitted=%d envStateReads=%d envStateEvents=%d envStateRetired=%d envSpentSkipped=%d envStateUnknown=%d envReset=%d envRetireEvents=%d envSuperseded=%d trapStateEvents=%d probeEvents=%d invalidateRetired=%d retired=%d retireReasons=%s invalid=%d quarantined=%d syncRequests=%d syncCoalesced=%d dynamicTracked=%d/%d dynamicSlices=%d dynamicReads=%d dynamicMoves=%d dynamicInvalid=%d bootstrapRuns=%d bootstrapHandlers=%d bootstrapReadText=%d bootstrapCpuMs=%.3f hooksRetired=%d hotHooks=%s governorRejected=%d refreshRateGated=%d walls=%s secretSeeds=%d secretReseeds=%d secretCandidates=%d secretAdmitted=%d secretRetired=%d secretOpenEvents=%d secretBeginEvents=%d secretNotify=%d secretStateReads=%d secretStateOpen=%d secretStateUnknown=%d secretPending=%d secretSeedCpuMs=%.3f secretSeedSkipped=%d secretSeedsSkipped=%d secretNotifySkipped=%d secretRecheckTracked=%d secretRecheckLooks=%d secretRecheckResolves=%d secretRecheckMissing=%d armLookups=%d armTimeSlices=%d deadHooks=%d enemySelfByClass=%d enemyPollReads=%d enemyPollMissing=%d churnDeferred=%d churnForced=%d seedDeferred=%d recurringGlobalScans=0 retainedStaticUObjects=0 retainedActorRefs=%d",
            tostring(reason or "manual"), count_records(), table.concat(category_text, "|"),
            armed, #HOOK_SPECS, m.hook_events, m.admitted, m.filtered,
            m.handler_lifecycle_begin, m.handler_lifecycle_end,
            m.handler_register, m.handler_unregister, m.actor_begin, m.actor_end,
            m.owner_end, m.owner_end_retired, m.owner_retire, m.owner_retire_retired,
            suppressed_hidden, suppressed_disabled, m.hidden_at_capture,
            m.handler_disable, m.handler_enable, m.handler_invalidate, m.handler_lock, m.handler_unlock,
            m.duplicate_sources, tonumber(m.shop_handlers) or 0, tonumber(m.recategorized) or 0,
            runtime.enemy_count, m.enemy_events, m.enemy_admitted, m.boss_admitted,
            m.enemy_refreshed, m.enemy_refresh_throttled, m.enemy_refresh_disabled, m.enemy_self_skipped or 0,
            m.enemy_deaths, m.enemy_decayed, m.enemy_skipped, m.enemy_friendly_skipped,
            m.corpse_checks, m.corpse_reads, m.corpse_dead, m.corpse_read_failures,
            m.hittable_admitted, m.hittable_retired, m.hittable_skipped,
            m.hittable_state_reads, m.hittable_state_spent, m.hittable_state_unknown,
            m.hittable_hits, m.hittable_regrown,
            m.env_shooting_events, m.trap_admitted, m.shootable_admitted,
            m.env_state_reads, m.env_state_events, m.env_state_retired, m.env_spent_skipped,
            m.env_state_unknown, m.env_reset, m.env_retire_events, m.env_superseded,
            m.trap_state_events, m.probe_events, m.invalidate_retired,
            m.retired, retire_text, m.invalid_contexts, m.quarantined_events,
            m.sync_requests, m.sync_coalesced, runtime.dynamic_ref_count, DYNAMIC_REF_CAP,
            m.dynamic_refresh_slices, m.dynamic_refresh_reads, m.dynamic_position_updates,
            m.dynamic_invalid_reads, m.bootstrap_runs, m.bootstrap_handler_candidates,
            m.bootstrap_readtext_candidates, m.bootstrap_cpu_ms,
            m.hooks_retired, hot_hook_text(), m.governor_rejected, m.refresh_rate_gated,
            walls_armed() and "armed" or "pending", m.secret_seeds, m.secret_reseeds,
            m.secret_seed_candidates, m.secret_admitted, m.secret_retired, m.secret_open_events,
            m.secret_begin_events, m.secret_notify_events, m.secret_state_reads,
            m.secret_state_open, m.secret_state_unknown, m.secret_location_pending,
            m.secret_seed_cpu_ms,
            m.secret_seed_skipped, m.secret_seeds_skipped, m.secret_notify_skipped,
            m.secret_recheck_tracked, m.secret_recheck_looks, m.secret_recheck_resolves,
            m.secret_recheck_missing, m.arm_lookups, m.arm_time_slices,
            dead_hook_count(), m.enemy_self_by_class or 0,
            m.enemy_poll_reads or 0, m.enemy_poll_missing or 0,
            m.churn_deferred or 0, m.churn_forced or 0, m.secret_seed_deferred or 0,
            retained_actor_refs()))
        -- v0.18.23: BOTH hotkeys, not just the light one. Her 131942 run was a Ctrl+Shift+Delete
        -- -- exactly the dump these lines were added for -- and they did not print, because
        -- v0.18.22 gated them on "ctrl-delete" alone. A diagnostic that only fires on the
        -- hotkey you did not press is not a diagnostic.
        local dump_reason = tostring(reason or "manual")
        if dump_reason == "ctrl-delete" or dump_reason == "ctrl-shift-delete" then
            -- Which hooks actually fired, most first. A hook that armed and sat at
            -- zero is the thing this line exists to expose.
            local fired = {}
            for hook_label, count in pairs(runtime.label_events) do
                fired[#fired + 1] = { label = hook_label, count = count }
            end
            table.sort(fired, function(a, b)
                if a.count ~= b.count then return a.count > b.count end
                return a.label < b.label
            end)
            local silent = {}
            for _, spec in ipairs(HOOK_SPECS) do
                if runtime.label_events[tostring(spec.label)] == nil then
                    silent[#silent + 1] = tostring(spec.label)
                end
            end
            table.sort(silent)
            local fired_text = {}
            for i = 1, #fired do
                fired_text[i] = fired[i].label .. ":" .. tostring(fired[i].count)
            end
            log("Local discovery hookEvents fired=" .. table.concat(fired_text, "|"))
            log("Local discovery hookEvents silent=" .. table.concat(silent, "|"))
            -- v0.18.23: the loudest line this layer can write, because the thing it
            -- reports cannot fix itself and will not show up as a crash.
            local dead = {}
            for dead_label in pairs(runtime.dead_hooks) do dead[#dead + 1] = dead_label end
            table.sort(dead)
            if #dead > 0 then
                log("Local discovery DEAD HOOKS (no such UFunction -- these names are WRONG"
                    .. " and will never arm, this is a BUG not a pending state) count="
                    .. tostring(#dead) .. " labels=" .. table.concat(dead, "|"))
                for _, dead_label in ipairs(dead) do
                    log("Local discovery deadHook label=" .. dead_label
                        .. " path=" .. tostring(runtime.dead_hooks[dead_label]))
                end
            end
            -- v0.18.22: which enemy classes actually get their marker moved, and by what.
            -- A class that appears in the admissions but NOT here has a frozen dot; a class
            -- here with no `ai.PlayFootstepVFX` entry is refreshed by something else, which
            -- is exactly the flying-enemy question. Printed only on the light Ctrl+Delete
            -- summary, one line per class, so it costs nothing until she asks for it.
            local classes = {}
            for class_name in pairs(runtime.enemy_refresh_by_class) do
                classes[#classes + 1] = class_name
            end
            table.sort(classes)
            for _, class_name in ipairs(classes) do
                local counts = runtime.enemy_refresh_by_class[class_name]
                local sources = {}
                for source, count in pairs(counts) do
                    if source ~= "total" then
                        sources[#sources + 1] = source .. ":" .. tostring(count)
                    end
                end
                table.sort(sources)
                log(string.format("Local discovery enemyRefresh class=%s total=%d by=%s",
                    class_name, counts.total, table.concat(sources, "|")))
            end
            if #classes == 0 then
                log("Local discovery enemyRefresh none=true"
                    .. " -- no enemy marker moved since this world loaded")
            end
            for i = 1, math.min(20, #nearest) do
                local record = nearest[i].record
                local distance = nearest[i].d2 < math.huge and math.sqrt(nearest[i].d2) / 100.0 or -1
                -- v0.17.0: the icon named here is the one the LOCAL tab has chosen for
                -- the category, not the record's default, so the log matches the map.
                local icon_path = record.texture_path
                if type(Classifier.ResolveArt) == "function" then
                    local chosen = Classifier.ResolveArt(record.category,
                        Config["LocalIcon" .. tostring(record.category)],
                        Config["LocalIconColor" .. tostring(record.category)])
                    if chosen ~= nil then icon_path = chosen end
                end
                log(string.format(
                    "Local discovery near rank=%d distanceM=%.3f category=%s icon=%s class=%s name=%s id=%s shown=%s hidden=%s disabled=%s invalidated=%d sources=%d location=(%.2f,%.2f,%.2f)",
                    i, distance, tostring(record.category),
                    tostring(string.match(tostring(icon_path or ""), "%.([^%.]+)$") or "none"),
                    tostring(record.class),
                    tostring(record.name), tostring(record.id), tostring(record.suppressed ~= true),
                    tostring(record.hidden == true),
                    tostring(type(record.disabled_by) == "table" and next(record.disabled_by) ~= nil),
                    tonumber(record.invalidate_count) or 0,
                    tonumber(record.source_count) or 0,
                    tonumber(record.x) or 0, tonumber(record.y) or 0, tonumber(record.z) or 0))
            end
            local filtered = {}
            for class_name, count in pairs(runtime.filtered_classes) do
                filtered[#filtered + 1] = { class_name = class_name, count = count }
            end
            table.sort(filtered, function(a, b)
                if a.count ~= b.count then return a.count > b.count end
                return a.class_name < b.class_name
            end)
            for i = 1, math.min(20, #filtered) do
                log(string.format("Local discovery filtered rank=%d count=%d class=%s",
                    i, filtered[i].count, filtered[i].class_name))
            end
            local states = {}
            for key, count in pairs(runtime.state_events) do states[#states + 1] = { key = key, count = count } end
            table.sort(states, function(a, b)
                if a.count ~= b.count then return a.count > b.count end
                return a.key < b.key
            end)
            for i = 1, math.min(24, #states) do
                log(string.format("Local discovery state rank=%d count=%d event=%s",
                    i, states[i].count, states[i].key))
            end
        end
    end

    function runtime.ArmedCount()
        local armed = 0
        for _, spec in ipairs(HOOK_SPECS) do if runtime.hooks[spec.path] ~= nil then armed = armed + 1 end end
        return armed, #HOOK_SPECS
    end

    return runtime
end

return Factory
