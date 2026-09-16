local MOD_NAME = "MortalShell2TTS"
-- v0.9.47 still reproduced the exit-time UObject purge crash after seven full
-- create/remove cycles. Retain one collapsed presentation shell for the process
-- instead: no delayed expiry callback, no repeated reader/InfoPanel allocation, and
-- no normal-close RemoveFromParent churn. A controller/world incompatibility can
-- still retire the cached shell on the next open. Negative means process-retained.
local SHELL_REUSE_MS = -1
local INPUT_CROSS_SOURCE_DEDUPE_SECONDS = 0.120
local VERSION = "0.9.263"
-- v0.9.262 Debug Logging toggle on the MOD tab (routine DIAG lines off by default; startup/session/failure events always logged); hold R / L3 on a row for 5 s to reset that row (ModUI 0.70.0 "reset-row"); example ini documents both switches.
-- v0.9.263 (user, pre-release) the hold-to-reset claim is cut from every line a user reads (the two row hints, the README, the changelog). She tested R and L3 on a row in TTS and in the minimap and neither reset anything. The wiring below stays: ResetSelected is correct and the fault is upstream in whether ModUI's hold detector ever fires. Text goes now, feature comes back when it is proven.
-- v0.9.261 Performance logging: Core/Perf.lua sections across scheduler dispatch/one-shots, reader, speech IPC, helper launch, file I/O, settings redraws, the shared input-host poll, the native UI observer and reader hooks; "Log Performance" toggle on the MOD tab; Ctrl+Delete summary; MortalShell2Perf.TTS shared flag for the ModUI host. Settings tabs may now exceed ten rows (ModUI scrolls).
-- v0.9.260 Pass 183 broad architecture audit transfers the proven modal-isolation implementation into shared ModUI ownership while preserving TTS session timing; helper/speech behavior remains unchanged.
-- v0.9.255 Pass 178 makes finite controller analog values authoritative at every magnitude so near-center samples cannot fall through to synthetic digital +/-1; consumer deadzone/activation policy remains above the physical reader.
-- v0.9.251 Pass 174 calibrates controller binding capture from two known post-zone L1+cardinal stick sweeps by using coherent hosted stick frames and direct-axis-first capture sampling; adaptive width remains pending user visual proof.
-- v0.9.246 Pass 169 extracts the complete Settings session/shell lifecycle, corrects the consumer-local shell observation state on the healthy ModUI path, and preserves the runtime-proven Pass-168 host/input behavior.
-- v0.9.245 Pass 168 extracts the complete TTS-side standalone-ModUI client/control plane while preserving the runtime-proven Pass-167 transition behavior.
-- v0.9.242 Pass 165 fixes the Pass-164 controller-observation extraction regression, refreshes shared-shell readiness synchronously on open, fail-closes fallback input acquisition, and requires a second confirmation before any settings reset.
-- v0.9.241 Pass 164 extracts consumer-local native presentation plus native UI observation/admission out of main.lua; Pass 163 runtime behavior remains unchanged.
-- v0.9.240 Pass 163 removes the temporary probe from production, hardens shared-shell consumer text bounds, and extracts TTS modal-isolation plus consumer-local semantic fallback systems out of main.lua.
-- v0.9.239 Pass 162 adds a host-owned closed-state provider selector plus a real independent second-consumer probe; Pass 161 shared semantic/shell continuity remains unchanged.
-- v0.9.236 Pass 159 closes Loading/transition Item 32 after clean death/reload proof; functional input behavior is unchanged.
-- v0.9.235 Pass 158 records save/load/relaunch evidence and narrows Loading/transition Item 32 to the remaining death/reload proof; functional input behavior is unchanged.
-- v0.9.234 Pass 157 records post-restoration stress evidence and redirects validation to the remaining save/load/shutdown release gate; functional input behavior is unchanged.
-- v0.9.233 Pass 156 closes the shared-input restoration roadmap after Pass-155 runtime proof; functional input behavior is unchanged.
-- v0.9.232 Pass 155 corrects repeated-input capture continuity exposed by the hosted open-hotkey
-- restoration. Capture now has exclusive physical-key authority over the saved OPEN binding,
-- neutral-rearm cannot preempt an active recorder, and hosted digital samples carry monotonic
-- pressSequence edges so a release/repress is not flattened into one held state. Capture-only
-- polling tightens to 20 ms; ordinary 50/250 ms cadence and Pass-154 transition quarantine stay.
-- v0.9.231 Pass 154 stages restoration checkpoint 4 with explicit LoadMap quarantine:
-- standalone ModUI owns physical OPEN-HOTKEY reads only after the consumer's proven
-- controller-identity/quiescence gate settles. LoadMap PRE republishes hotkey_provider=false;
-- the host drops its cached controller without validating it, and consumer fallback owns the
-- transition window until the settled new-world controller transactionally re-enables hosting.
-- v0.9.230 Pass 153 preserves the Pass-152 host-owned physical listener across descriptor
-- revision changes by republishing its revision-bound request before acknowledgement reset
-- and reasserting it after bounded acknowledgement; checkpoint 2 remains rejected.
-- v0.9.229 Pass 152 stages restoration checkpoint 3 without reviving rejected checkpoint 2.
-- ModUI owns the physical Settings WBP_InputListener, while TTS retains exactly one local
-- per-session InputTriggeredCallback hook and accepts callbacks only from the host-published
-- primitive listener address. The unsafe ModUI process-wide callback mirror remains isolated.
-- v0.9.228 Pass 151 rejects restoration checkpoint 2 after Pass 150 reproduced the historical
-- CBADB8CF transition crash immediately after LoadMap -> fresh Settings ready. The ModUI
-- process-wide InputTriggeredCallback hook is re-isolated and TTS returns to exactly one local
-- per-session hook. Pass 150's permanent main-chunk local-budget headroom remains unchanged.
-- v0.9.227 Pass 150 attempted shared-native restoration checkpoint 2 and is retained as rejected A/B history.
-- v0.9.226 Pass 149 corrects the Pass-148 startup local-budget regression while retaining its analog fix.
-- The producer-authority calculation is nested inside read_modui_host_axis instead of consuming another
-- top-level local slot in the already-at-limit composition chunk.
-- v0.9.225 Pass 148 fixes stale host-analog authority after Pass-147 local native-semantic restoration:
-- host axis cache is authoritative only while an actual host analog producer is active; otherwise
-- Voice Browser/details fall through to the proven local PlayerController analog reader. Controller
-- capture release also clears cached host-axis values so capture samples cannot leak into later UI.
-- v0.9.224 Pass 147 begins controlled native-input restoration from the Pass-146 crash-stable
-- baseline: keep the consumer-owned WBP_InputListener and restore exactly one TTS-local
-- per-session InputTriggeredCallback hook while the ModUI process-wide hook stays isolated.
-- v0.9.223 Pass 146 scopes native-UI observation to the current Settings handler and adds
-- delayed-poll phase breadcrumbs while preserving Pass 145 close-quarantine/rearm safety.
-- Pass 145 makes the entire input poll UObject-free during close quarantine and
-- requires a fully neutral sample after every toggle request, denied edge, and host/local
-- ownership change. This closes the exact held-chord re-admission/session-churn race captured
-- in Pass 144 while retaining its transition quiescence and fresh post-load edge gate.
-- v0.9.221 Pass 144 keeps Pass 143's pre-invalidation LoadMap freeze and hardens the first
-- post-travel Settings edge: controller identity must remain stable for 2 seconds, then another
-- 2-second quiescence stage must pass, and the configured open binding must be observed neutral
-- before a fresh edge is accepted. This prevents held/spammed L3+R3 from falling through exactly
-- when the transition gate changes from blocked to eligible.
-- v0.9.220 Pass 143 moves transition detection ahead of UObject invalidation. Pass 142 proved
-- the recurring UE4SS crash can occur with ZERO Settings sessions and ZERO InputTriggeredCallback
-- hooks while the closed-menu consumer still caches/validates a MainMenu PlayerController. UE4SS
-- LoadMap pre/post hooks now freeze all consumer input polling before world teardown, drop cached
-- controller/shell identities without dereferencing them, and resume only after a primitive post-load
-- delay. Pass 147 now restores only the TTS-local per-session InputTriggeredCallback hook; the
-- ModUI process-wide hook remains isolated so restoration changes exactly one callback layer.
-- Pass 137 transition crash A/B: retain the shared ModUI native-input mirror and
-- all host control-plane semantics, but temporarily keep physical WBP_InputListener
-- construction in the consumer-owned, Pass-124-proven InputBridge path. This preserves
-- exactly one physical listener while isolating standalone ModUI listener ownership.
local schedule_pending_speech = nil
local schedule_close_finalize = nil
local schedule_shell_cache_expiry = nil

-- v0.9.41 diagnostic session sequencing. The diagnostic stream is intentionally
-- machine-readable enough that a UE4SS.log can be compared step-by-step after a
-- crash or partial setup without relying on visual symptoms alone.
local dd = {}

-- Pass 57 advances the runtime-aware ModUI boundary into a cohesive listener-local input
-- bridge host: route discovery, AcceptedInputs ownership, hook lifecycle, and binding
-- activation/retirement now share one ordered transaction. Listener object lifetime timing,
-- callback semantics, dispatch, world/shell ownership, pause/effects, and the 225 ms close
-- quarantine remain TTS-owned.
local function unwrap(value)
    return dd.ModUI.Object.Unwrap(value)
end

local function valid(value)
    return dd.ModUI.Object.Valid(value)
end

local function object_name(object)
    return dd.ModUI.Object.Name(object)
end

local function text_string(value)
    return dd.ModUI.Object.TextString(value)
end

local function widget_text(widget)
    return dd.ModUI.Object.WidgetText(widget)
end

local function script_path()
    local ok, info = pcall(function() return debug.getinfo(1, "S") end)
    if not ok or info == nil then return nil end
    local source = tostring(info.source or "")
    if source:sub(1, 1) == "@" then source = source:sub(2) end
    if source == "" then return nil end
    return source:gsub("/", "\\")
end

local function parent_path(path)
    if path == nil then return nil end
    return path:match("^(.*)\\[^\\]+$")
end

local scripts_dir = parent_path(script_path())
local mod_dir = parent_path(scripts_dir) or "Mods\\MortalShell2TTS"

-- Pass 102 moves sanitized logging / machine-readable diagnostic sequencing and
-- repeat-session compaction into a bounded runtime-host module. The consumer still
-- owns the meaning of every event and decides when events are emitted.
local diagnostics_chunk, diagnostics_load_error = loadfile(scripts_dir .. "\\Runtime\\Diagnostics.lua")
if diagnostics_chunk == nil then
    print(string.format("[%s] Runtime.Diagnostics could not be loaded. Re-extract the release ZIP.\n", MOD_NAME))
    return
end
local diagnostics_ok, DiagnosticsFactory = pcall(diagnostics_chunk)
if not diagnostics_ok or type(DiagnosticsFactory) ~= "table" or type(DiagnosticsFactory.New) ~= "function" then
    print(string.format("[%s] Runtime.Diagnostics is invalid. Re-extract the release ZIP.\n", MOD_NAME))
    return
end
local runtime_diagnostics = DiagnosticsFactory.New({
    mod_name = MOD_NAME,
    mod_dir = mod_dir,
    print_fn = print,
    -- v0.9.262: nil until TTSConfig.ini has been read (dd.config_load_source stays
    -- "defaults" until then), so startup logs in full; afterwards the MOD tab's
    -- Debug Logging switch decides.
    debug_enabled = function()
        if type(dd.config) ~= "table" or dd.config_loaded ~= true then return nil end
        return dd.config.debug_logging == true
    end,
})
if type(runtime_diagnostics) ~= "table"
    or type(runtime_diagnostics.Log) ~= "function"
    or type(runtime_diagnostics.Diag) ~= "function"
    or type(runtime_diagnostics.Session) ~= "function"
    or type(runtime_diagnostics.BeginSession) ~= "function" then
    print(string.format("[%s] Runtime.Diagnostics API is incomplete. Re-extract the release ZIP.\n", MOD_NAME))
    return
end
dd.RuntimeDiagnostics = runtime_diagnostics
local function log(message) return runtime_diagnostics.Log(message) end
local function diag(event, fields) return runtime_diagnostics.Diag(event, fields) end
diag("dependency.runtimeDiagnostics", { module = "Runtime.Diagnostics", ownership = "runtime-diagnostic-stream", status = "ready" })

local helper_path = mod_dir .. "\\TTSHelper.ps1"
local payload_path = mod_dir .. "\\tts_command.txt"
local sequence_path = mod_dir .. "\\tts_sequence.txt"
local config_path = mod_dir .. "\\TTSConfig.ini"
local voices_path = mod_dir .. "\\tts_voices.txt"
local audio_outputs_path = mod_dir .. "\\tts_outputs.txt"
local TTS_COMMAND_IPC_MAX_BYTES = 512 * 1024
local azure_voices_path = mod_dir .. "\\tts_azure_voices.txt"
local engine_status_path = mod_dir .. "\\tts_engine_status.txt"
dd.helper_heartbeat_path = mod_dir .. "\\tts_helper_heartbeat.txt"
dd.HELPER_HEARTBEAT_MAX_AGE_SECONDS = 8
dd.HELPER_RESTART_COOLDOWN_SECONDS = 5

-- v0.9.161 support-evidence anchor. This is intentionally emitted before config
-- loading or helper startup so a support bundle can scope runtime evidence to the
-- final contiguous run of this exact mod version instead of accidentally mixing
-- older 0.9.x diagnostics from a long-lived UE4SS.log.
diag("startup.begin", {
    version = VERSION,
    phase = "module-load",
})

-- v0.9.218 Pass 141 hard-isolates the process-wide InputTriggeredCallback hook. TTS keeps one consumer listener and one local per-session hook; ModUI registers no process-wide hook during this A/B. Pass 135/136 admission remains active.
-- v0.9.214 Pass 137 isolates the recurrent transition crash at the native-listener ownership boundary: TTS uses one consumer-owned WBP_InputListener while the standalone host mirror/control plane remains active.
-- v0.9.187 Pass 110 closes the Pass-109 startup corrective, hardens host-binding republish diagnostics, and republishes host descriptors for Modifier Sides + Reset changes without moving another ownership boundary.
-- v0.9.186 Pass 109 corrects ModUI public-API startup composition; Pass-108 open-hotkey ownership is otherwise unchanged and still awaits target-game proof.
-- v0.9.185 Pass 108 migrates physical OPEN-HOTKEY polling into standalone ModUI Host.InputService after Pass-107 handshake proof; native menu/capture/browser/details input remains consumer-scoped and fail-soft fallback is retained.
-- v0.9.183 Pass 106 established the first primitive-only cross-Lua-state ModUI Host.Protocol/Registry registration path while preserving Pass-105 ModUI InputHost ownership, Pass-104 fail-soft core-lore startup isolation, and the accepted/frozen MAI preview cadence.
-- v0.9.179 Pass 102 extracts Runtime.Diagnostics and tightens the preview-only MAI cadence guard to documented zero-millisecond breaks after listening found only a slight residual pause before Two; normal lore synthesis remains unchanged.
-- v0.9.178 Pass 101 resumes host decomposition with Runtime.Scheduler + UI.Pointer and restores the preferred two-sentence preview behind an Azure-only preview cadence guard; normal lore synthesis remains unchanged.
-- v0.9.177 Pass 100 records Pass-99 target-game proof plus architecture accounting; the v0.9.176 bind-capture fail-safe corrective remains unchanged and runtime behavior is intentionally identical apart from version/evidence metadata.
-- v0.9.175 Pass 98 accelerates modularization with Settings.Presentation + Settings.Controller and a smoother one-sentence voice-preview phrase; native hook/input/modal lifetimes remain host-owned.
-- v0.9.172 Pass 95 accelerates modularization with a coordinated runtime batch: per-voice profile state/migration, speech request/duplicate/dispatch orchestration, and helper heartbeat/restart/PowerShell-launch ownership move into dedicated modules while Unreal UI/input/modal teardown remains frozen.
-- v0.9.171 Pass 94 extracts bounded helper engine-status snapshot refresh/invalidation orchestration into Engine.Runtime; helper lifecycle, Azure catalog parsing/synthesis, Settings UI/input/modal ownership and speech behavior remain consumer-owned.
-- v0.9.170 Pass 93 extracts bounded audio-output catalog runtime orchestration into Audio.Runtime; helper/synthesis, native UI/input/modal ownership and speech behavior remain consumer-owned.
-- v0.9.168 Pass 91 freezes the independently reproduced native Quit-confirmation race, removes the ineffective confirmation lifecycle hook, retains the proven read-only native-state observer, and extracts delayed narration orchestration into Speech.Queue.
-- v0.9.167 Pass 90 corrected tri-state false preservation in the native UI observer and added a diagnostic confirmation hook; runtime evidence later showed that hook observed the borrowed TTS ReadText shell rather than the native Default confirmation path.
-- v0.9.166 Pass 89 added the initial read-only native UI transition observer backed by MortalShell2ModUI Runtime.NativeState.
-- v0.9.165 Pass 88 extracts the atomic file/sequence TTS command publisher into Scripts\Speech\IPC.lua; helper lifecycle policy, speech queue timing, reader behavior, UI/input/modal isolation and Azure synthesis remain consumer-owned and unchanged.
-- v0.9.164 Pass 87 extracts persisted-config load/sanitize/save orchestration into Scripts\Config\Runtime.lua; Unreal/runtime ownership, config filesystem mechanics, codec, voice profiles, helper/Azure, input, modal isolation, and pronunciation remain unchanged.
-- v0.9.162 Pass 85 extracts the read-only native-widget/donor diagnostics into Scripts\UI\Diagnostics.lua; no widget ownership, shell lifetime, input, modal isolation, narration or pronunciation behavior moves.
-- v0.9.161 Pass 84 adds a short Speech > Pronunciation On/Off toggle, freezes pronunciation feature work after Pass-83 runtime proof, and returns the roadmap to broader pre-1.0/modularization work; ModUI/input behavior remains frozen.
-- v0.9.160 Pass 83 keeps the proven PowerShell 5.1 loader/matcher and adds helper-side selected-voice pronunciation capability routing with per-rule spelling fallback; ModUI/input behavior remains frozen.
-- v0.9.158 Pass 81 restores Windows PowerShell 5.1 startup by keeping BOM-less executable PowerShell source ASCII-safe; Pass 80 IPA data/transport semantics remain otherwise unchanged.
-- v0.9.157 Pass 80 moves the two runtime-heard pronunciation corrections to explicit Azure IPA/SSML phonemes after Pass 79 proved plain respellings remained inconsistent; shared input/session behavior remains unchanged.
-- v0.9.155 Pass 78 corrects the helper-side Windows PowerShell 5.1 List[object] conversion boundary exposed by Pass 77 runtime evidence. The Pass-77 ordinal scanner, synthesis-boundary normalization, and input/session behavior remain unchanged.
-- v0.9.149 Pass 72 moves the post-quarantine consumer barrier -> authorization -> retirement ordering behind the shared host while TTS still owns the quarantine clock and the modal-isolation release callback itself.
-- v0.9.147 Pass 70 extends the proven Pass-69 keyboard/native dedupe to Left/Right value navigation; all four primary arrow directions now use the same first-arrival-wins cross-source claim while same-source repeat remains unchanged.
-- v0.9.146 Pass 69 dedupes direct Up/Down RegisterKeyBind navigation against the same keyboard-generated IA_Menu Up/Down event when the native listener transiently reports gamepad feedback mode; same-source keyboard repeat remains unchanged.
-- v0.9.145 Pass 68 adds explicit TTS-owned retirement authorization to the shared teardown ticket; ModUI enforces authorization but TTS still owns the quarantine/modal-isolation timing decision.
-- v0.9.144 Pass 67 adds a shared teardown ticket that pairs the exact deactivation ownership with later retirement; TTS still owns semantic dispatch and exactly when deactivation/retirement are safe.
-- v0.9.142 Pass 65 moves lease-owned versus legacy teardown-option fallback selection behind MortalShell2ModUI; TTS still owns semantic dispatch and exactly when deactivation/retirement are safe.
-- v0.9.139 Pass 62 moves only generic replaceable-handler slot installation into MortalShell2ModUI Runtime.InputBridge; the MortalShell2TTS-supplied handler function still owns generation/session validation and semantic dispatch.
-- v0.9.137 Pass 60 corrects only the Voice Browser mouse-row Y hit origin using the proven main-row origin + Browser padding delta; pointer normalization, 40.5 row pitch, horizontal regions, selection/activation semantics and all keyboard/controller routing remain unchanged.
-- v0.9.136 Pass 59 adds shared Runtime.InputBridge lease ownership so listener + activation/deactivation/retirement state stay cohesive while TTS still owns class selection and exactly when teardown/retirement are safe.
-- v0.9.135 Pass 58 extended the shared Runtime.InputBridge host through listener construction, viewport attachment, handler association, activation and failure cleanup while TTS retained class selection and lifecycle timing.
-- v0.9.134 Pass 57 added shared Runtime.InputBridge activation/deactivation sequencing and extracted TTS-specific bridge diagnostics/state adaptation into Input.BridgeDiagnostics.
-- v0.9.133 Pass 56 added shared Runtime.Bridge lifecycle transactions for WBP_InputListener
-- Create/viewport attach/handler association/removal while TTS retained class discovery,
-- lifecycle timing, callback semantics, dispatch, diagnostics and close quarantine.
-- v0.9.132 Pass 55 advanced shared Runtime.Hook into bounded UE4SS hook registration/retirement
-- transactions.
-- v0.9.131 Pass 54 advanced shared Runtime.Listener into bounded binding enable/disable
-- transactions.
-- v0.9.130 Pass 53 advances runtime-aware framework extraction with shared listener
-- AcceptedInputs mutation/verification/restoration. Diagnostics, hooks/polling, dispatch,
-- listener creation/lifetime, widget/shell/world ownership, pause/effects, and teardown remain consumer-owned.
-- v0.9.127 Pass 50 introduced shared read-only property/method observation and
-- admission-snapshot acquisition plus modular helper-heartbeat parsing.
-- v0.9.126 Pass 49 introduced shared native-array observation and admission policy.
-- v0.9.125 Pass 48 introduced shared safe UObject/FText helpers and Config.Storage.
-- v0.9.122 Pass 45 closes the adjustable-value mouse dead zone: the standardized
-- Previous/< band ends at the exact reference-space boundary where Next begins.
-- v0.9.121 Pass 44 closes the world-interaction isolation gap by adding Mortal
-- Shell's exact GE_Block_Interact effect to the TTS-owned modal handle set.
-- v0.9.120 Pass 43 realigns main-row/value pointer bounds to the rendered rails after
-- Pass-42 follow-up measurement. The UE4SS-incompatible UTF-8 BOM guard remains.
-- World lifecycle, physical-input policy, clocks/diagnostics, action dispatch,
-- file I/O, helper/Azure synchronization, shell ownership, Browser behavior, and
-- speech dispatch remain consumer-owned.
dd.load_lua_table_module = function(path, label)
    local chunk, load_err = loadfile(path)
    if chunk == nil then
        log("dependency load failed " .. tostring(label) .. ": " .. tostring(load_err))
        return nil, tostring(load_err)
    end
    local ok, result = pcall(chunk)
    if not ok then
        log("dependency init failed " .. tostring(label) .. ": " .. tostring(result))
        return nil, tostring(result)
    end
    if type(result) ~= "table" then
        log("dependency init failed " .. tostring(label) .. ": module did not return a table")
        return nil, "module-did-not-return-table"
    end
    return result, nil
end

dd.ModUI, dd.modui_error = dd.load_lua_table_module((parent_path(mod_dir) or "Mods") .. "\\MortalShell2ModUI\\Scripts\\ModUI.lua", "MortalShell2ModUI")
if dd.ModUI == nil
    or type(dd.ModUI.Text) ~= "table"
    or type(dd.ModUI.Value) ~= "table"
    or type(dd.ModUI.Object) ~= "table"
    or type(dd.ModUI.Object.Unwrap) ~= "function"
    or type(dd.ModUI.Object.Valid) ~= "function"
    or type(dd.ModUI.Object.Name) ~= "function"
    or type(dd.ModUI.Object.TextString) ~= "function"
    or type(dd.ModUI.Object.WidgetText) ~= "function"
    or type(dd.ModUI.Object.Address) ~= "function"
    or type(dd.ModUI.Object.Same) ~= "function"
    or type(dd.ModUI.Array) ~= "table"
    or type(dd.ModUI.Array.Count) ~= "function"
    or type(dd.ModUI.Array.ByteValues) ~= "function"
    or type(dd.ModUI.Array.ObjectEntries) ~= "function"
    or type(dd.ModUI.Array.NameString) ~= "function"
    or type(dd.ModUI.Runtime) ~= "table"
    or type(dd.ModUI.Runtime.Admission) ~= "table"
    or type(dd.ModUI.Runtime.Admission.Evaluate) ~= "function"
    or type(dd.ModUI.Runtime.Observation) ~= "table"
    or type(dd.ModUI.Runtime.Observation.SafeProperty) ~= "function"
    or type(dd.ModUI.Runtime.Observation.SafeBoolMethod) ~= "function"
    or type(dd.ModUI.Runtime.Observation.AdmissionSnapshot) ~= "function"
    or type(dd.ModUI.Runtime.Observation.MenuQuery) ~= "function"
    or type(dd.ModUI.Runtime.PhysicalBinding) ~= "table"
    or type(dd.ModUI.Runtime.PhysicalBinding.New) ~= "function"
    or type(dd.ModUI.Runtime.NativeState) ~= "table"
    or type(dd.ModUI.Runtime.NativeState.NewTracker) ~= "function"
    or type(dd.ModUI.Runtime.NativeState.Observe) ~= "function"
    or type(dd.ModUI.Runtime.Resolve) ~= "table"
    or type(dd.ModUI.Runtime.Resolve.PlayerController) ~= "function"
    or type(dd.ModUI.Runtime.Resolve.UIHandlerWithFallback) ~= "function"
    or type(dd.ModUI.Runtime.Listener) ~= "table"
    or type(dd.ModUI.Runtime.Listener.BuildRoutes) ~= "function"
    or type(dd.ModUI.Runtime.Listener.ControllerIsGamepad) ~= "function"
    or type(dd.ModUI.Runtime.Listener.AcceptanceSnapshot) ~= "function"
    or type(dd.ModUI.Runtime.Listener.ConfigureAcceptedInputs) ~= "function"
    or type(dd.ModUI.Runtime.Listener.RestoreAcceptedInputs) ~= "function"
    or type(dd.ModUI.Runtime.Listener.EnableBindings) ~= "function"
    or type(dd.ModUI.Runtime.Listener.DisableBindings) ~= "function"
    or type(dd.ModUI.Runtime.Hook) ~= "table"
    or type(dd.ModUI.Runtime.Hook.Register) ~= "function"
    or type(dd.ModUI.Runtime.Hook.Unregister) ~= "function"
    or type(dd.ModUI.Runtime.Bridge) ~= "table"
    or type(dd.ModUI.Runtime.Bridge.CreateListener) ~= "function"
    or type(dd.ModUI.Runtime.Bridge.AttachViewport) ~= "function"
    or type(dd.ModUI.Runtime.Bridge.EnsureHandler) ~= "function"
    or type(dd.ModUI.Runtime.Bridge.RemoveListener) ~= "function"
    or type(dd.ModUI.Runtime.InputBridge) ~= "table"
    or type(dd.ModUI.Runtime.InputBridge.Activate) ~= "function"
    or type(dd.ModUI.Runtime.InputBridge.Deactivate) ~= "function"
    or type(dd.ModUI.Runtime.InputBridge.Open) ~= "function"
    or type(dd.ModUI.Runtime.InputBridge.Retire) ~= "function"
    or type(dd.ModUI.Runtime.InputBridge.DeactivateLease) ~= "function"
    or type(dd.ModUI.Runtime.InputBridge.RetireLease) ~= "function"
    or type(dd.ModUI.Runtime.InputBridge.EnsureStableTrampoline) ~= "function"
    or type(dd.ModUI.Runtime.InputBridge.InstallStableHandler) ~= "function"
    or type(dd.ModUI.Runtime.InputBridge.DeactivateOwned) ~= "function"
    or type(dd.ModUI.Runtime.InputBridge.ResolveDeactivateOptions) ~= "function"
    or type(dd.ModUI.Runtime.InputBridge.ResolveDeactivateActivation) ~= "function"
    or type(dd.ModUI.Runtime.InputBridge.RetireOwned) ~= "function"
    or type(dd.ModUI.Runtime.InputBridge.BeginOwnedTeardown) ~= "function"
    or type(dd.ModUI.Runtime.InputBridge.AuthorizeOwnedTeardown) ~= "function"
    or type(dd.ModUI.Runtime.InputBridge.FinishOwnedTeardown) ~= "function"
    or type(dd.ModUI.Runtime.InputBridge.CompleteOwnedTeardown) ~= "function"
    or type(dd.ModUI.Runtime.InputBridge.CompleteOwnedTeardownAfterBarrier) ~= "function"
    or type(dd.ModUI.Runtime.InputBridge.BeginTeardownTransaction) ~= "function"
    or type(dd.ModUI.Runtime.InputBridge.CompleteTeardownTransaction) ~= "function"
    or type(dd.ModUI.Runtime.InputBridge.BeginTeardownPlan) ~= "function"
    or type(dd.ModUI.Runtime.InputBridge.CompleteTeardownPlan) ~= "function"
    or type(dd.ModUI.Runtime.InputBridge.OpenSession) ~= "function"
    or type(dd.ModUI.Runtime.InputBridge.BeginSessionTeardown) ~= "function"
    or type(dd.ModUI.Runtime.InputBridge.CompleteSessionTeardown) ~= "function"
    or type(dd.ModUI.Host) ~= "table"
    or type(dd.ModUI.Host.Protocol) ~= "table"
    or type(dd.ModUI.Host.Registry) ~= "table"
    or type(dd.ModUI.Host.InputService) ~= "table"
    or type(dd.ModUI.Input) ~= "table"
    or type(dd.ModUI.Input.Binding) ~= "table"
    or type(dd.ModUI.Input.Conflict) ~= "table"
    or type(dd.ModUI.Input.Capture) ~= "table"
    or type(dd.ModUI.Input.Capture.NewState) ~= "function"
    or type(dd.ModUI.Input.Capture.NewStickGate) ~= "function"
    or type(dd.ModUI.Input.Capture.ResolveStickDirection) ~= "function"
    or type(dd.ModUI.Input.Capture.InputsLabel) ~= "function"
    or type(dd.ModUI.Input.Capture.ResolveCommit) ~= "function"
    or type(dd.ModUI.Input.Repeat) ~= "table"
    or type(dd.ModUI.Input.Repeat.AdvanceHeld) ~= "function"
    or type(dd.ModUI.Input.Repeat.AdvanceDirectional) ~= "function"
    or type(dd.ModUI.Input.Route) ~= "table"
    or type(dd.ModUI.Input.Route.Action) ~= "function"
    or type(dd.ModUI.Input.Route.ClaimCrossSource) ~= "function"
    or type(dd.ModUI.Input.Acceptance) ~= "table"
    or type(dd.ModUI.Input.Acceptance.ListCsv) ~= "function"
    or type(dd.ModUI.Input.Acceptance.SetDiff) ~= "function"
    or type(dd.ModUI.Input.Acceptance.Contains) ~= "function"
    or type(dd.ModUI.Settings) ~= "table"
    or type(dd.ModUI.Settings.Model) ~= "table"
    or type(dd.ModUI.Settings.Render) ~= "table"
    or type(dd.ModUI.Settings.Navigation) ~= "table"
    or type(dd.ModUI.Settings.Details) ~= "table"
    or type(dd.ModUI.Controller) ~= "table"
    or type(dd.ModUI.Controller.Profile) ~= "table"
    or type(dd.ModUI.Controller.Profile.Reload) ~= "function"
    or type(dd.ModUI.Controller.Profile.CenteredStick) ~= "function"
    or type(dd.ModUI.Controller.Profile.NormalizeStick) ~= "function"
    or type(dd.ModUI.Controller.Settings) ~= "table"
    or type(dd.ModUI.Controller.Settings.New) ~= "function"
    or tonumber(dd.ModUI.API_VERSION) == nil
    or tonumber(dd.ModUI.API_VERSION) < 1 then
    diag("dependency.modui", {
        status = "missing-or-incompatible",
        expectedApi = 1,
        actualApi = dd.ModUI ~= nil and tostring(dd.ModUI.API_VERSION) or "<missing>",
        error = dd.modui_error,
    })
    log("MortalShell2ModUI API v1+ is required. Re-extract both mod folders from the same release ZIP.")
    return
end

dd.SettingsSchema, dd.settings_schema_error = dd.load_lua_table_module(scripts_dir .. "\\Settings\\Schema.lua", "Settings.Schema")
if dd.SettingsSchema == nil or type(dd.SettingsSchema.tabs) ~= "table" or type(dd.SettingsSchema.descriptions) ~= "table" then
    diag("dependency.settingsSchema", {
        status = "missing-or-invalid",
        error = dd.settings_schema_error,
    })
    log("MortalShell2TTS settings schema is missing or invalid. Re-extract the release ZIP.")
    return
end

local schema_ok, schema_reason = dd.ModUI.Settings.Model.ValidateSchema(dd.SettingsSchema.tabs)
if not schema_ok then
    diag("dependency.settingsSchema", {
        status = "framework-validation-failed",
        error = schema_reason,
    })
    log("MortalShell2TTS settings schema failed MortalShell2ModUI validation: " .. tostring(schema_reason))
    return
end

dd.SettingsOptions, dd.settings_options_error = dd.load_lua_table_module(scripts_dir .. "\\Settings\\Options.lua", "Settings.Options")
if dd.SettingsOptions == nil or type(dd.SettingsOptions.engines) ~= "table" or type(dd.SettingsOptions.azure_regions) ~= "table" then
    diag("dependency.settingsOptions", {
        status = "missing-or-invalid",
        error = dd.settings_options_error,
    })
    log("MortalShell2TTS settings options are missing or invalid. Re-extract the release ZIP.")
    return
end

dd.SettingsPresentationFactory, dd.settings_presentation_error = dd.load_lua_table_module(scripts_dir .. "\\Settings\\Presentation.lua", "Settings.Presentation")
if dd.SettingsPresentationFactory == nil or type(dd.SettingsPresentationFactory.New) ~= "function" then
    diag("dependency.settingsPresentation", { status = "missing-or-invalid", error = dd.settings_presentation_error })
    log("MortalShell2TTS Settings presentation module is missing or invalid. Re-extract the release ZIP.")
    return
end

dd.SettingsControllerFactory, dd.settings_controller_error = dd.load_lua_table_module(scripts_dir .. "\\Settings\\Controller.lua", "Settings.Controller")
if dd.SettingsControllerFactory == nil or type(dd.SettingsControllerFactory.New) ~= "function" then
    diag("dependency.settingsController", { status = "missing-or-invalid", error = dd.settings_controller_error })
    log("MortalShell2TTS Settings controller module is missing or invalid. Re-extract the release ZIP.")
    return
end

-- Pass 160: ModUI owns the one canonical native Settings/browser geometry table.
-- TTS consumes that shared layout for semantic pointer hit-testing and its bounded
-- fail-soft local-shell fallback so host rendering and consumer interaction cannot drift.
dd.UILayout = type(dd.ModUI) == "table" and type(dd.ModUI.Settings) == "table" and dd.ModUI.Settings.Layout or nil
dd.ui_layout_error = dd.UILayout ~= nil and nil or "MortalShell2ModUI.Settings.Layout unavailable"
if dd.UILayout == nil
    or type(dd.UILayout.assets) ~= "table"
    or type(dd.UILayout.widths) ~= "table"
    or type(dd.UILayout.settings) ~= "table"
    or type(dd.UILayout.enums) ~= "table" then
    diag("dependency.uiLayout", {
        status = "missing-or-invalid",
        owner = "MortalShell2ModUI.Settings.Layout",
        error = dd.ui_layout_error,
    })
    log("MortalShell2ModUI shared Settings layout is missing or invalid. Re-extract the release ZIP.")
    return
end

dd.VoiceBrowserState, dd.voice_browser_state_error = dd.load_lua_table_module(scripts_dir .. "\\VoiceBrowser\\State.lua", "VoiceBrowser.State")
if dd.VoiceBrowserState == nil or type(dd.VoiceBrowserState.New) ~= "function" then
    diag("dependency.voiceBrowserState", {
        status = "missing-or-invalid",
        error = dd.voice_browser_state_error,
    })
    log("MortalShell2TTS Voice Browser state module is missing or invalid. Re-extract the release ZIP.")
    return
end

dd.VoiceBrowserCatalog, dd.voice_browser_catalog_error = dd.load_lua_table_module(scripts_dir .. "\\VoiceBrowser\\Catalog.lua", "VoiceBrowser.Catalog")
if dd.VoiceBrowserCatalog == nil
    or type(dd.VoiceBrowserCatalog.Rebuild) ~= "function"
    or type(dd.VoiceBrowserCatalog.Rows) ~= "function"
    or type(dd.VoiceBrowserCatalog.CycleGender) ~= "function"
    or type(dd.VoiceBrowserCatalog.EditQuery) ~= "function" then
    diag("dependency.voiceBrowserCatalog", {
        status = "missing-or-invalid",
        error = dd.voice_browser_catalog_error,
    })
    log("MortalShell2TTS Voice Browser catalog module is missing or invalid. Re-extract the release ZIP.")
    return
end

dd.VoiceBrowserRuntimeFactory, dd.voice_browser_runtime_factory_error = dd.load_lua_table_module(scripts_dir .. "\\VoiceBrowser\\Runtime.lua", "VoiceBrowser.Runtime")
if dd.VoiceBrowserRuntimeFactory == nil or type(dd.VoiceBrowserRuntimeFactory.New) ~= "function" then
    diag("dependency.voiceBrowserRuntime", {
        status = "missing-or-invalid",
        error = dd.voice_browser_runtime_factory_error,
    })
    log("MortalShell2TTS Voice Browser runtime module is missing or invalid. Re-extract the release ZIP.")
    return
end

dd.VoiceBrowserControllerFactory, dd.voice_browser_controller_factory_error = dd.load_lua_table_module(scripts_dir .. "\\VoiceBrowser\\Controller.lua", "VoiceBrowser.Controller")
if dd.VoiceBrowserControllerFactory == nil or type(dd.VoiceBrowserControllerFactory.New) ~= "function" then
    diag("dependency.voiceBrowserController", { status = "missing-or-invalid", error = dd.voice_browser_controller_factory_error })
    log("MortalShell2TTS Voice Browser controller module is missing or invalid. Re-extract the release ZIP.")
    return
end

dd.ConfigDefaults, dd.config_defaults_error = dd.load_lua_table_module(scripts_dir .. "\\Config\\Defaults.lua", "Config.Defaults")
if dd.ConfigDefaults == nil or type(dd.ConfigDefaults.New) ~= "function" then
    diag("dependency.configDefaults", {
        status = "missing-or-invalid",
        error = dd.config_defaults_error,
    })
    log("MortalShell2TTS config defaults module is missing or invalid. Re-extract the release ZIP.")
    return
end


dd.ConfigSanitize, dd.config_sanitize_error = dd.load_lua_table_module(scripts_dir .. "\\Config\\Sanitize.lua", "Config.Sanitize")
if dd.ConfigSanitize == nil
    or type(dd.ConfigSanitize.QueueBehavior) ~= "function"
    or type(dd.ConfigSanitize.DuplicateWindow) ~= "function"
    or type(dd.ConfigSanitize.Text) ~= "function"
    or type(dd.ConfigSanitize.Binding) ~= "function"
    or type(dd.ConfigSanitize.Favorites) ~= "function" then
    diag("dependency.configSanitize", {
        status = "missing-or-invalid",
        error = dd.config_sanitize_error,
    })
    log("MortalShell2TTS config sanitization module is missing or invalid. Re-extract the release ZIP.")
    return
end

dd.ConfigCodec, dd.config_codec_error = dd.load_lua_table_module(scripts_dir .. "\\Config\\Codec.lua", "Config.Codec")
if dd.ConfigCodec == nil
    or type(dd.ConfigCodec.SnapshotValid) ~= "function"
    or type(dd.ConfigCodec.Serialize) ~= "function" then
    diag("dependency.configCodec", {
        status = "missing-or-invalid",
        error = dd.config_codec_error,
    })
    log("MortalShell2TTS config codec module is missing or invalid. Re-extract the release ZIP.")
    return
end

dd.ConfigStorage, dd.config_storage_error = dd.load_lua_table_module(scripts_dir .. "\\Config\\Storage.lua", "Config.Storage")
if dd.ConfigStorage == nil
    or type(dd.ConfigStorage.Write) ~= "function"
    or type(dd.ConfigStorage.WriteAtomic) ~= "function"
    or type(dd.ConfigStorage.Read) ~= "function"
    or type(dd.ConfigStorage.Exists) ~= "function"
    or type(dd.ConfigStorage.WriteConfigAtomic) ~= "function" then
    diag("dependency.configStorage", {
        status = "missing-or-invalid",
        error = dd.config_storage_error,
    })
    log("MortalShell2TTS config storage module is missing or invalid. Re-extract the release ZIP.")
    return
end

dd.ConfigRuntime, dd.config_runtime_error = dd.load_lua_table_module(scripts_dir .. "\\Config\\Runtime.lua", "Config.Runtime")
if dd.ConfigRuntime == nil
    or type(dd.ConfigRuntime.Sanitize) ~= "function"
    or type(dd.ConfigRuntime.Load) ~= "function"
    or type(dd.ConfigRuntime.Save) ~= "function" then
    diag("dependency.configRuntime", {
        status = "missing-or-invalid",
        error = dd.config_runtime_error,
    })
    log("MortalShell2TTS config runtime module is missing or invalid. Re-extract the release ZIP.")
    return
end
diag("dependency.configRuntime", {
    status = "ready",
    module = "Config.Runtime",
    ownership = "persisted-config-lifecycle",
})

dd.VoiceProfiles, dd.voice_profiles_error = dd.load_lua_table_module(scripts_dir .. "\\Config\\VoiceProfiles.lua", "Config.VoiceProfiles")
if dd.VoiceProfiles == nil
    or type(dd.VoiceProfiles.Escape) ~= "function"
    or type(dd.VoiceProfiles.Unescape) ~= "function"
    or type(dd.VoiceProfiles.Key) ~= "function"
    or type(dd.VoiceProfiles.Default) ~= "function"
    or type(dd.VoiceProfiles.Sanitize) ~= "function"
    or type(dd.VoiceProfiles.Deserialize) ~= "function"
    or type(dd.VoiceProfiles.Serialize) ~= "function" then
    diag("dependency.voiceProfiles", {
        status = "missing-or-invalid",
        error = dd.voice_profiles_error,
    })
    log("MortalShell2TTS voice-profile serialization module is missing or invalid. Re-extract the release ZIP.")
    return
end

dd.VoiceProfileRuntimeFactory, dd.voice_profile_runtime_error = dd.load_lua_table_module(scripts_dir .. "\\Config\\VoiceProfileRuntime.lua", "Config.VoiceProfileRuntime")
if dd.VoiceProfileRuntimeFactory == nil or type(dd.VoiceProfileRuntimeFactory.New) ~= "function" then
    diag("dependency.voiceProfileRuntime", { status = "missing-or-invalid", error = dd.voice_profile_runtime_error })
    log("MortalShell2TTS voice-profile runtime module is missing or invalid. Re-extract the release ZIP.")
    return
end

dd.AudioOutputs, dd.audio_outputs_error = dd.load_lua_table_module(scripts_dir .. "\\Audio\\Outputs.lua", "Audio.Outputs")
if dd.AudioOutputs == nil or type(dd.AudioOutputs.Parse) ~= "function" then
    diag("dependency.audioOutputs", {
        status = "missing-or-invalid",
        error = dd.audio_outputs_error,
    })
    log("MortalShell2TTS audio-output parser module is missing or invalid. Re-extract the release ZIP.")
    return
end

dd.AudioRuntimeFactory, dd.audio_runtime_factory_error = dd.load_lua_table_module(scripts_dir .. "\\Audio\\Runtime.lua", "Audio.Runtime")
if dd.AudioRuntimeFactory == nil or type(dd.AudioRuntimeFactory.New) ~= "function" then
    diag("dependency.audioRuntime", {
        status = "missing-or-invalid",
        error = dd.audio_runtime_factory_error,
    })
    log("MortalShell2TTS audio-output runtime module is missing or invalid. Re-extract the release ZIP.")
    return
end

dd.EngineStatus, dd.engine_status_error = dd.load_lua_table_module(scripts_dir .. "\\Engine\\Status.lua", "Engine.Status")
if dd.EngineStatus == nil or type(dd.EngineStatus.Parse) ~= "function" then
    diag("dependency.engineStatus", {
        status = "missing-or-invalid",
        error = dd.engine_status_error,
    })
    log("MortalShell2TTS engine-status parser module is missing or invalid. Re-extract the release ZIP.")
    return
end

dd.EngineRuntimeFactory, dd.engine_runtime_factory_error = dd.load_lua_table_module(scripts_dir .. "\\Engine\\Runtime.lua", "Engine.Runtime")
if dd.EngineRuntimeFactory == nil or type(dd.EngineRuntimeFactory.New) ~= "function" then
    diag("dependency.engineRuntime", {
        status = "missing-or-invalid",
        error = dd.engine_runtime_factory_error,
    })
    log("MortalShell2TTS engine-status runtime module is missing or invalid. Re-extract the release ZIP.")
    return
end

dd.SpeechDuplicate, dd.speech_duplicate_error = dd.load_lua_table_module(scripts_dir .. "\\Speech\\Duplicate.lua", "Speech.Duplicate")
if dd.SpeechDuplicate == nil
    or type(dd.SpeechDuplicate.RequestKey) ~= "function"
    or type(dd.SpeechDuplicate.Check) ~= "function" then
    diag("dependency.speechDuplicate", {
        status = "missing-or-invalid",
        error = dd.speech_duplicate_error,
    })
    log("MortalShell2TTS duplicate-speech policy module is missing or invalid. Re-extract the release ZIP.")
    return
end

dd.SpeechRuntimeFactory, dd.speech_runtime_error = dd.load_lua_table_module(scripts_dir .. "\\Speech\\Runtime.lua", "Speech.Runtime")
if dd.SpeechRuntimeFactory == nil or type(dd.SpeechRuntimeFactory.New) ~= "function" then
    diag("dependency.speechRuntime", { status = "missing-or-invalid", error = dd.speech_runtime_error })
    log("MortalShell2TTS speech runtime module is missing or invalid. Re-extract the release ZIP.")
    return
end

dd.SpeechIPC, dd.speech_ipc_error = dd.load_lua_table_module(scripts_dir .. "\\Speech\\IPC.lua", "Speech.IPC")
if dd.SpeechIPC == nil or type(dd.SpeechIPC.New) ~= "function" then
    diag("dependency.speechIPC", {
        status = "missing-or-invalid",
        error = dd.speech_ipc_error,
    })
    log("MortalShell2TTS speech IPC module is missing or invalid. Re-extract the release ZIP.")
    return
end

dd.SpeechQueue, dd.speech_queue_error = dd.load_lua_table_module(scripts_dir .. "\\Speech\\Queue.lua", "Speech.Queue")
if dd.SpeechQueue == nil or type(dd.SpeechQueue.New) ~= "function" then
    diag("dependency.speechQueue", {
        status = "missing-or-invalid",
        error = dd.speech_queue_error,
    })
    log("MortalShell2TTS speech queue module is missing or invalid. Re-extract the release ZIP.")
    return
end

dd.ReaderRuntimeFactory, dd.reader_runtime_factory_error = dd.load_lua_table_module(scripts_dir .. "\\Reader\\Runtime.lua", "Reader.Runtime")
if dd.ReaderRuntimeFactory == nil or type(dd.ReaderRuntimeFactory.New) ~= "function" then
    diag("dependency.readerRuntime", { status = "missing-or-invalid", error = dd.reader_runtime_factory_error })
    log("MortalShell2TTS reader runtime module is missing or invalid. Re-extract the release ZIP.")
    return
end

dd.HelperHeartbeat, dd.helper_heartbeat_error = dd.load_lua_table_module(scripts_dir .. "\\Helper\\Heartbeat.lua", "Helper.Heartbeat")
if dd.HelperHeartbeat == nil or type(dd.HelperHeartbeat.Evaluate) ~= "function" then
    diag("dependency.helperHeartbeat", {
        status = "missing-or-invalid",
        error = dd.helper_heartbeat_error,
    })
    log("MortalShell2TTS helper-heartbeat parser module is missing or invalid. Re-extract the release ZIP.")
    return
end

dd.HelperRuntimeFactory, dd.helper_runtime_error = dd.load_lua_table_module(scripts_dir .. "\\Helper\\Runtime.lua", "Helper.Runtime")
if dd.HelperRuntimeFactory == nil or type(dd.HelperRuntimeFactory.New) ~= "function" then
    diag("dependency.helperRuntime", { status = "missing-or-invalid", error = dd.helper_runtime_error })
    log("MortalShell2TTS helper runtime module is missing or invalid. Re-extract the release ZIP.")
    return
end

dd.InputBridgeDiagnosticsFactory, dd.input_bridge_diagnostics_error = dd.load_lua_table_module(scripts_dir .. "\\Input\\BridgeDiagnostics.lua", "Input.BridgeDiagnostics")
if dd.InputBridgeDiagnosticsFactory == nil or type(dd.InputBridgeDiagnosticsFactory.Bind) ~= "function" then
    diag("dependency.inputBridgeDiagnostics", {
        status = "missing-or-invalid",
        error = dd.input_bridge_diagnostics_error,
    })
    log("MortalShell2TTS input-bridge diagnostics adapter is missing or invalid. Re-extract the release ZIP.")
    return
end

diag("dependency.modui", {
    status = "ready",
    version = tostring(dd.ModUI.VERSION or "<unknown>"),
    api = tonumber(dd.ModUI.API_VERSION) or 0,
    coreValue = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("value") or false,
    runtimeObject = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("object") or false,
    runtimeArray = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("array") or false,
    runtimeObservation = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("runtimeObservation") or false,
    runtimeResolve = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("runtimeResolve") or false,
    runtimeListener = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("runtimeListener") or false,
    runtimeListenerMutation = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("runtimeListenerMutation") or false,
    runtimeListenerBindings = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("runtimeListenerBindings") or false,
    runtimeHook = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("runtimeHook") or false,
    runtimeBridgeLifecycle = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("runtimeBridgeLifecycle") or false,
    runtimeInputBridge = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("runtimeInputBridge") or false,
    runtimeInputBridgeConstruction = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("runtimeInputBridgeConstruction") or false,
    runtimeInputBridgeLease = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("runtimeInputBridgeLease") or false,
    runtimeInputBridgeTrampoline = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("runtimeInputBridgeTrampoline") or false,
    runtimeInputBridgeHandlerSlot = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("runtimeInputBridgeHandlerSlot") or false,
    runtimeInputBridgeLeaseHookSpec = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("runtimeInputBridgeLeaseHookSpec") or false,
    runtimeInputBridgeLeaseRouter = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("runtimeInputBridgeLeaseRouter") or false,
    runtimeInputBridgeLeaseTeardownOptions = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("runtimeInputBridgeLeaseTeardownOptions") or false,
    runtimeInputBridgeLeaseTeardownActivation = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("runtimeInputBridgeLeaseTeardownActivation") or false,
    runtimeInputBridgeTeardownTicket = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("runtimeInputBridgeTeardownTicket") or false,
    runtimeInputBridgeTeardownAuthorization = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("runtimeInputBridgeTeardownAuthorization") or false,
    runtimeInputBridgeTeardownCompletion = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("runtimeInputBridgeTeardownCompletion") or false,
    runtimeInputBridgeTeardownBarrier = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("runtimeInputBridgeTeardownBarrier") or false,
    runtimeInputBridgeTeardownTransaction = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("runtimeInputBridgeTeardownTransaction") or false,
    runtimeInputBridgeTeardownPlan = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("runtimeInputBridgeTeardownPlan") or false,
    runtimeInputBridgeSession = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("runtimeInputBridgeSession") or false,
    runtimeInputHost = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("runtimeInputHost") or false,
    runtimeInputHostConsumerScoped = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("runtimeInputHostConsumerScoped") or false,
    runtimeControllerAnalog = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("runtimeControllerAnalog") or false,
    hostProtocol = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("hostProtocol") or false,
    hostRegistry = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("hostRegistry") or false,
    hostRegistryPrimitiveOnly = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("hostRegistryPrimitiveOnly") or false,
    hostService = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("hostService") or false,
    hostRegistrationAck = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("hostRegistrationAck") or false,
    hostInputService = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("hostInputService") or false,
    hostPhysicalHotkeyInput = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("hostPhysicalHotkeyInput") or false,
    hostPhysicalRightStickY = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("hostPhysicalRightStickY") or false,
    hostPhysicalControllerAnalog = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("hostPhysicalControllerAnalog") or false,
    hostPhysicalControllerCapture = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("hostPhysicalControllerCapture") or false,
    hostPhysicalKeyboardCapture = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("hostPhysicalKeyboardCapture") or false,
    hostPhysicalKeyboardNavigation = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("hostPhysicalKeyboardNavigation") or false,
    hostNativePointerSnapshot = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("hostNativePointerSnapshot") or false,
    hostPhysicalNativeListener = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("hostPhysicalNativeListener") or false,
    hostDiscoveryBounded = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("hostDiscoveryBounded") or false,
    hostSinglePhysicalInput = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("hostSinglePhysicalInput") or false,
    runtimeNativeState = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("runtimeNativeState") or false,
    runtimeAdmission = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("runtimeAdmission") or false,
    inputBinding = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("inputBinding") or false,
    inputConflict = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("inputConflict") or false,
    inputCapture = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("inputCapture") or false,
    inputRepeat = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("inputRepeat") or false,
    inputRoute = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("inputRoute") or false,
    inputAcceptance = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("inputAcceptance") or false,
    settingsModel = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("settingsModel") or false,
    settingsRender = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("settingsRender") or false,
    settingsNavigation = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("settingsNavigation") or false,
    settingsDetails = dd.ModUI.HasCapability ~= nil and dd.ModUI.HasCapability("settingsDetails") or false,
})

local function write_file(path, value)
    return dd.ConfigStorage.Write(path, value, log)
end

-- Performance logging (Core/Perf.lua, byte-identical with the Minimap/ModUI copies;
-- PERFORMANCE_LOGGING.md). dd.perf is this mod's profiler; the ModUI library loaded into
-- this Lua state reports to it too (open-bind poll, shared-variable traffic). Off by
-- default and free when off. config.log_performance turns it on (dd.sync_perf), and the
-- summary timer runs on the game-thread scheduler once that exists.
dd.PerfFactory, dd.perf_factory_error = dd.load_lua_table_module(scripts_dir .. "\\Core\\Perf.lua", "Core.Perf")
if dd.PerfFactory == nil or type(dd.PerfFactory.New) ~= "function" then
    error("MortalShell2TTS Core.Perf failed to load: " .. tostring(dd.perf_factory_error or "missing API"))
end
dd.perf = dd.PerfFactory.New({
    mod = "TTS",
    log = log,
    clock = os.clock,
    schedule = function(delay_ms, callback)
        if type(dd.schedule_perf_summary) ~= "function" then return false end
        return dd.schedule_perf_summary(delay_ms, callback)
    end,
})
dd.ModUI.Perf = dd.perf
local PERF_SHARED_KEY = "MortalShell2Perf.TTS"
-- Mirrors config.log_performance into the profiler and publishes the flag the shared
-- ModUI host follows. Called after config load, on the settings toggle, and on reset.
function dd.sync_perf(reason)
    local wanted = type(dd.config) == "table" and dd.config.log_performance == true
    if dd.perf.SetEnabled(wanted, reason or "setting") then
        if ModRef ~= nil and type(ModRef.SetSharedVariable) == "function" then
            pcall(ModRef.SetSharedVariable, ModRef, PERF_SHARED_KEY, wanted and 1 or 0)
        end
    end
    return wanted
end
diag("dependency.perf", { module = "Core.Perf", ownership = "performance-sections+10s-summary", status = "ready" })

-- IPC/config files are handed to the helper by replacement, never while the
-- destination itself is still open for writing. This avoids a Windows sharing
-- race between UE4SS/Lua and the helper's polling reads.
local function write_file_atomic(path, value)
    local token = dd.perf.Begin()
    local ok = dd.ConfigStorage.WriteAtomic(path, value, log)
    dd.perf.End("io.write", token)
    return ok
end

local function read_file(path, max_bytes)
    local token = dd.perf.Begin()
    local content = dd.ConfigStorage.Read(path, max_bytes)
    dd.perf.End("io.read", token)
    return content
end

local function file_exists(path)
    return dd.ConfigStorage.Exists(path)
end

-- Config writes keep the previous complete snapshot until the replacement is
-- published. IPC files intentionally retain their proven lightweight replacement
-- path above because they are rewritten frequently while the helper is polling.
function dd.write_config_atomic(path, value)
    local token = dd.perf.Begin()
    local ok, err = (function()
        return dd.ConfigStorage.WriteConfigAtomic(path, value, dd.config_snapshot_valid, log)
    end)()
    dd.perf.End("io.config.write", token)
    return ok, err
end

local trim = dd.ModUI.Value.Trim

local clamp = dd.ModUI.Value.Clamp
local bool_from_string = dd.ModUI.Value.BoolFromString
local config = dd.ConfigDefaults.New()
dd.config = config

dd.CONFIG_SCHEMA = 3
dd.config_load_source = "defaults"
dd.config_loaded_schema = 1

dd.normalize_queue_behavior = dd.ConfigSanitize.QueueBehavior
dd.normalize_duplicate_window = dd.ConfigSanitize.DuplicateWindow
dd.sanitize_config_text = dd.ConfigSanitize.Text
dd.sanitize_binding_string = dd.ConfigSanitize.Binding
dd.sanitize_favorites_string = dd.ConfigSanitize.Favorites
dd.config_snapshot_valid = dd.ConfigCodec.SnapshotValid

function dd.sanitize_loaded_config()
    return dd.ConfigRuntime.Sanitize(config, dd.ModUI.Value, dd.ConfigSanitize)
end

-- Per-voice profile state is module-owned; legacy host function names remain as
-- thin compatibility adapters so the proven UI/browser callers stay unchanged.
dd.voice_profile_runtime, dd.voice_profile_runtime_init_error = dd.VoiceProfileRuntimeFactory.New({
    config = config,
    profiles = dd.VoiceProfiles,
    value_helpers = dd.ModUI.Value,
    diag = diag,
    log = log,
    schema = dd.CONFIG_SCHEMA,
})
if dd.voice_profile_runtime == nil
    or type(dd.voice_profile_runtime.Reset) ~= "function"
    or type(dd.voice_profile_runtime.Serialize) ~= "function"
    or type(dd.voice_profile_runtime.Deserialize) ~= "function"
    or type(dd.voice_profile_runtime.Profile) ~= "function"
    or type(dd.voice_profile_runtime.Capture) ~= "function"
    or type(dd.voice_profile_runtime.Apply) ~= "function"
    or type(dd.voice_profile_runtime.Initialize) ~= "function" then
    error("MortalShell2TTS Config.VoiceProfileRuntime failed: " .. tostring(dd.voice_profile_runtime_init_error or "missing API"))
end
diag("dependency.voiceProfileRuntime", { module = "Config.VoiceProfileRuntime", ownership = "per-voice-profile-runtime", status = "ready" })

dd.default_voice_profile = dd.VoiceProfiles.Default
function dd.sanitize_voice_profile(profile) return dd.VoiceProfiles.Sanitize(profile, dd.ModUI.Value) end
function dd.serialize_voice_profiles() return dd.voice_profile_runtime.Serialize() end
function dd.deserialize_voice_profiles(serialized) return dd.voice_profile_runtime.Deserialize(serialized) end
function dd.voice_profile(engine, voice, create) return dd.voice_profile_runtime.Profile(engine, voice, create) end
function dd.capture_voice_profile(engine, voice) return dd.voice_profile_runtime.Capture(engine, voice) end
function dd.apply_voice_profile(engine, voice) return dd.voice_profile_runtime.Apply(engine, voice) end
function dd.initialize_voice_profiles(previous_schema) return dd.voice_profile_runtime.Initialize(previous_schema) end

local function load_config()
    local loaded, source, loaded_schema = dd.ConfigRuntime.Load(config, {
        config_path = config_path,
        read_file = read_file,
        write_file_atomic = write_file_atomic,
        snapshot_valid = dd.config_snapshot_valid,
        trim = trim,
        bool_from_string = bool_from_string,
        clamp = clamp,
        value_helpers = dd.ModUI.Value,
        sanitize = dd.ConfigSanitize,
        log = log,
    })
    dd.config_load_source = tostring(source or "defaults")
    dd.config_loaded_schema = tonumber(loaded_schema) or 1
    -- Whether the file existed or not, the user's Debug Logging choice is now known.
    dd.config_loaded = true
    return loaded == true
end

local function save_config()
    local token = dd.perf.Begin()
    local ok, err = dd.ConfigRuntime.Save(config, {
        config_path = config_path,
        schema = dd.CONFIG_SCHEMA,
        value_helpers = dd.ModUI.Value,
        sanitize = dd.ConfigSanitize,
        codec = dd.ConfigCodec,
        serialize_voice_profiles = dd.serialize_voice_profiles,
        write_config_atomic = dd.write_config_atomic,
    })
    dd.perf.End("io.config.save", token)
    return ok, err
end

-- Helper process policy is module-owned. Keep stable host adapters for the IPC,
-- settings and startup callers so this extraction does not alter call timing.
dd.helper_runtime, dd.helper_runtime_init_error = dd.HelperRuntimeFactory.New({
    perf = dd.perf,
    version = VERSION,
    helper_path = helper_path,
    heartbeat_path = dd.helper_heartbeat_path,
    heartbeat = dd.HelperHeartbeat,
    read_file = read_file,
    file_exists = file_exists,
    max_age_seconds = dd.HELPER_HEARTBEAT_MAX_AGE_SECONDS,
    restart_cooldown_seconds = dd.HELPER_RESTART_COOLDOWN_SECONDS,
    log = log,
    diag = diag,
})
if dd.helper_runtime == nil
    or type(dd.helper_runtime.HeartbeatFresh) ~= "function"
    or type(dd.helper_runtime.Start) ~= "function"
    or type(dd.helper_runtime.EnsureRunning) ~= "function" then
    error("MortalShell2TTS Helper.Runtime failed: " .. tostring(dd.helper_runtime_init_error or "missing API"))
end
diag("dependency.helperRuntime", { module = "Helper.Runtime", ownership = "heartbeat-launch-recovery-runtime", status = "ready" })
function dd.helper_heartbeat_fresh(now_epoch) return dd.helper_runtime.HeartbeatFresh(now_epoch) end
function dd.start_helper(reason, prefer_path_fallback) return dd.helper_runtime.Start(reason, prefer_path_fallback) end
function dd.ensure_helper_running(reason) return dd.helper_runtime.EnsureRunning(reason) end

dd.speech_ipc, dd.speech_ipc_error = dd.SpeechIPC.New({
    payload_path = payload_path,
    sequence_path = sequence_path,
    max_payload_bytes = TTS_COMMAND_IPC_MAX_BYTES,
    read_file = read_file,
    write_file_atomic = write_file_atomic,
    trim = trim,
    log = log,
    ensure_helper_running = function(command)
        if dd.ensure_helper_running ~= nil then dd.ensure_helper_running(command) end
    end,
})
if dd.speech_ipc == nil or type(dd.speech_ipc.Command) ~= "function" then
    error("MortalShell2TTS Speech.IPC runtime failed: " .. tostring(dd.speech_ipc_error or "missing API"))
end
diag("dependency.speechIPC", { module = "Speech.IPC", ownership = "atomic-command-sequence-publish", status = "ready" })

local function tts_command(command, text)
    local token = dd.perf.Begin()
    local ok, err = dd.speech_ipc.Command(command, text)
    dd.perf.End("speech.command", token)
    return ok, err
end

-- Speech request composition/duplicate state/dispatch are module-owned. The
-- real-time Unreal clock and delayed-action scheduler remain consumer-owned.
dd.speech_runtime, dd.speech_runtime_init_error = dd.SpeechRuntimeFactory.New({
    config = config,
    duplicate = dd.SpeechDuplicate,
    command = tts_command,
    normalize_window = dd.normalize_duplicate_window,
    save_config = save_config,
    real_time_seconds = function()
        if type(dd.real_time_seconds) == "function" then return dd.real_time_seconds() end
        return nil, "os.time"
    end,
    log = log,
    diag = diag,
})
if dd.speech_runtime == nil
    or type(dd.speech_runtime.ResetDuplicates) ~= "function"
    or type(dd.speech_runtime.RequestKey) ~= "function"
    or type(dd.speech_runtime.SpokenText) ~= "function"
    or type(dd.speech_runtime.SpeakNow) ~= "function"
    or type(dd.speech_runtime.DuplicateSuppressed) ~= "function"
    or type(dd.speech_runtime.Stop) ~= "function"
    or type(dd.speech_runtime.Test) ~= "function" then
    error("MortalShell2TTS Speech.Runtime failed: " .. tostring(dd.speech_runtime_init_error or "missing API"))
end
diag("dependency.speechRuntime", { module = "Speech.Runtime", ownership = "speech-request-runtime", status = "ready" })
function dd.narration_request_key(text, page) return dd.speech_runtime.RequestKey(text, page) end
function dd.duplicate_narration_suppressed(text, page) return dd.speech_runtime.DuplicateSuppressed(text, page) end
local function speak_now(text, page) return dd.speech_runtime.SpeakNow(text, page) end
local function stop_speech(reason) return dd.speech_runtime.Stop(reason) end
local function test_voice() return dd.speech_runtime.Test() end

local function cancel_speech_delay()
    local rt = _G.MortalShell2TTSRuntime
    if rt ~= nil and rt.speech_delay_handle ~= nil and type(CancelDelayedAction) == "function" then
        local handle = rt.speech_delay_handle
        local ok, result = pcall(CancelDelayedAction, handle)
        diag("delay.cancel", {
            field = "speech_delay_handle",
            handle = tostring(handle),
            callOk = ok,
            cancelRequestFound = ok and tostring(result) or "<error>",
            error = ok and nil or result,
            source = "Speech.Queue",
        })
        rt.speech_delay_handle = nil
    end
end

dd.speech_queue, dd.speech_queue_error = dd.SpeechQueue.New({
    narration_enabled = function() return config.narration == true end,
    delay_ms = function() return tonumber(config.read_delay_ms) or 0 end,
    duplicate_suppressed = function(text, page) return dd.duplicate_narration_suppressed(text, page) end,
    speak_now = speak_now,
    schedule_delay = function(delay_ms)
        return schedule_pending_speech ~= nil and schedule_pending_speech(delay_ms) == true
    end,
    cancel_delay = cancel_speech_delay,
    log = log,
})
if dd.speech_queue == nil
    or type(dd.speech_queue.Clear) ~= "function"
    or type(dd.speech_queue.Queue) ~= "function"
    or type(dd.speech_queue.Process) ~= "function"
    or type(dd.speech_queue.HasPending) ~= "function" then
    error("MortalShell2TTS Speech.Queue runtime failed: " .. tostring(dd.speech_queue_error or "missing API"))
end
diag("dependency.speechQueue", { module = "Speech.Queue", ownership = "delayed-narration-orchestration", status = "ready" })
local function clear_pending_speech() dd.speech_queue.Clear() end
local function queue_speech(text, page, reason) dd.speech_queue.Queue(text, page, reason) end
local function process_pending_speech() dd.speech_queue.Process() end

-- Lore-reader state/discovery/content lifecycle are module-owned. Exact UE4SS
-- hook registration remains in this host so hook identity/lifetime stay unchanged.
dd.reader_runtime, dd.reader_runtime_error = dd.ReaderRuntimeFactory.New({
    perf = dd.perf,
    unwrap = unwrap,
    valid = valid,
    object_name = object_name,
    widget_text = widget_text,
    find_all = function(class_name) return FindAllOf(class_name) end,
    settings_widget_name = function()
        if type(dd.SettingsSession) == "table" and type(dd.SettingsSession.WidgetObjectName) == "function" then
            return dd.SettingsSession.WidgetObjectName()
        end
        return nil
    end,
    clear_pending_speech = clear_pending_speech,
    queue_speech = queue_speech,
    process_pending_speech = process_pending_speech,
    stop_speech = stop_speech,
    log = log,
    diag = diag,
})
if dd.reader_runtime == nil
    or type(dd.reader_runtime.Read) ~= "function"
    or type(dd.reader_runtime.HandleContent) ~= "function"
    or type(dd.reader_runtime.HandleClose) ~= "function"
    or type(dd.reader_runtime.IsOpen) ~= "function" then
    error("MortalShell2TTS Reader.Runtime failed: " .. tostring(dd.reader_runtime_error or "missing API"))
end
diag("dependency.readerRuntime", { module = "Reader.Runtime", ownership = "lore-reader-lifecycle-state", status = "ready" })
local function read_reader() return dd.reader_runtime.Read() end
local function handle_reader_content_event(current, reason) return dd.reader_runtime.HandleContent(current, reason) end
local function handle_reader_close_event(current, reason) return dd.reader_runtime.HandleClose(current, reason) end

-- Event-driven lore-reader lifecycle. Hook registration remains consumer-owned.
dd.ReaderHookPaths = {
    InitMultiText = "/Game/Sparta/UI/Menu/Misc/WBP_ConfirmationPrompt_ReadText.WBP_ConfirmationPrompt_ReadText_C:InitMultiText",
    SetReadText = "/Game/Sparta/UI/Menu/Misc/WBP_ConfirmationPrompt_ReadText.WBP_ConfirmationPrompt_ReadText_C:SetReadText",
    ChangePage = "/Game/Sparta/UI/Menu/Misc/WBP_ConfirmationPrompt_ReadText.WBP_ConfirmationPrompt_ReadText_C:ChangePage",
    PreFadeOutEvent = "/Game/Sparta/UI/Menu/Misc/WBP_ConfirmationPrompt_ReadText.WBP_ConfirmationPrompt_ReadText_C:PreFadeOutEvent",
    OnMenuClose = "/Game/Sparta/UI/Menu/Misc/WBP_ConfirmationPrompt_ReadText.WBP_ConfirmationPrompt_ReadText_C:OnMenuClose",
}

-- ---------------------------------------------------------------------------
-- In-game settings UI v0.9.49 distributed-column composition + retained passive shell, preserving native normalized mouse routing on the frozen v0.9.18 backend
-- Scalable three-tab foundation: Mod / Speech / Engine. The visual shell uses
-- Mortal Shell II's cooked lore-reader Widget Blueprint for visuals only. A
-- separate generic WBP_InputListener owns controller input so the reader's own
-- TextList/ReadIndex navigation can never receive settings Left/Right.
-- The selected-setting details column uses the game's real WBP_Setting_InfoPanel,
-- attached inside Overlay_Prompt so both columns share one prompt/background. The
-- panel's bright native background is suppressed; only its setting typography/divider remain.
-- ---------------------------------------------------------------------------

local ui = {
    open = false,
    closing = false,
    close_reason = nil,
    close_quarantine_ticks = 0,
    tab = 1,
    selected = 1,
    selected_by_tab = { 1, 1, 1 },
    status = "",
    pending_reset_key = "",
    pending_reset_generation = 0,
    voices = {},
    voice_catalog_engine = "",
    audio_outputs = {},
    engine_status_raw = "",
    azure_key_status = "missing",
    azure_ready = false,
    azure_voice_count = 0,
    azure_message = "",
    menu_key = "Ctrl+Del",
    widget = nil,
    host_visible_shell = false,
    host_visible_shell_generation = 0,
    host_visible_shell_last_sequence = 0,
    host_visible_shell_last_status = "startup",
    header_widget = nil,
    body_widget = nil,
    page_widget = nil,
    native_details_divider = nil, -- legacy field retained nil for cleanup compatibility
    native_details_widget = nil,
    native_tabs_widget = nil,
    native_tabs_text = nil,
    native_tabs_slot = nil,
    native_labels_widget = nil,
    native_labels_text = nil,
    native_labels_slot = nil,
    native_values_widget = nil,
    native_values_text = nil,
    native_values_slot = nil,
    native_prompt_box = nil,
    native_background = nil,
    native_source_body = nil,
    window_profile = "main",
    native_details_container = nil,
    native_details_overlay = nil,
    native_details_slot = nil,
    native_read_text_size_box = nil,
    native_read_text_scale_box = nil,
    native_read_text_root_child = nil,
    native_read_text_chain = "",
    native_reader_vb_data = nil,
    presentation_mode = "fallback",
    native_error_logged = false,
    redraw_sequence = 0,
    render_text_cache = {},
    render_set_calls = 0,
    render_set_skips = 0,
    session_generation = 0,
    active_generation = 0,
    close_generation = 0,
    invalid_session_logged = false,
    shell_cache = nil,
    shell_cache_token = 0,
    controller = nil,
    widget_library = nil,
    native_listener = nil,
    native_host_listener_primary = false,
    native_host_listener_address = "",
    native_host_listener_fallback_scheduled = false,
    native_input_bridge = nil,
    native_bridge_lease = nil,
    native_bridge_activation = nil,
    native_bridge_external_hook = false,
    native_listener_enabled = false,
    native_interface_input_enabled = false,
    native_ui_handler = nil,
    native_ui_input_enabled = false,
    native_input_hooks_ready = false,
    native_last_source = "",
    native_route_by_enum = {},
    native_route_by_action = {},
    native_action_name_by_enum = {},
    native_verified_accepted_inputs = {},
    native_original_accepted_inputs = nil,
    native_accepted_inputs_changed = false,
    native_pause_component = nil,
    native_pause_bumped = false,
    native_pause_bumps = 0,
    native_pause_reason = nil,
    native_modal_handler = nil,
    native_modal_asc = nil,
    native_modal_handles = {},
    native_modal_pending_cleanup = nil,
    native_modal_isolation = false,
    native_modal_mode = "none",
    native_menu_block_verified = false,
    native_modal_pre_map_allowed = nil,
    native_modal_pre_options_allowed = nil,
    native_gamepad_probe_warned = false,
    mouse_input_ready = false,
    mouse_click_count = 0,
    mouse_last_region = "",
    details_scroll_context = "",
    details_scroll_offset = 0,
    details_scroll_max = 0,
    details_scroll_total_lines = 0,
    details_scroll_axis_accum = 0.0,
    input_dedupe_last_semantic = "",
    input_dedupe_last_source_kind = "",
    input_dedupe_last_clock = -1.0,
    input_dedupe_count = 0,
    modal_input_active = false,
    modal_keybind_seen = false,
    modal_keybind_confirmed = false,
    modal_watch_age_ticks = 0,
    saved_show_cursor = false,
    saved_click_events = false,
    saved_hover_events = false,
    saved_move_ignored = false,
    saved_look_ignored = false,
    saved_move_probe_ok = false,
    saved_look_probe_ok = false,
    move_ignore_bumped = false,
    look_ignore_bumped = false,
    restore_input_hint = "game",
    admission_block_signature = "",
    admission_block_repeat_count = 0,
}

dd.voice_browser = dd.VoiceBrowserState.New()

local engines = dd.SettingsOptions.engines
local azure_regions = dd.SettingsOptions.azure_regions

local tabs = dd.SettingsSchema.tabs
local row_descriptions = dd.SettingsSchema.descriptions

local function row_description(row)
    return dd.settings_presentation.RowDescription(row)
end

local function row_control_hint(row)
    return dd.settings_presentation.RowControlHint(row)
end

function dd.voice_browser_active()
    if dd.settings_presentation ~= nil then return dd.settings_presentation.VoiceBrowserActive() end
    return type(dd.voice_browser) == "table" and dd.voice_browser.active == true
end

local function current_tab()
    return dd.settings_presentation.CurrentTab()
end

local function current_rows()
    return dd.settings_presentation.CurrentRows()
end

dd.engine_runtime, dd.engine_runtime_error = dd.EngineRuntimeFactory.New({
    config = config,
    ui = ui,
    read_file = read_file,
    parser = dd.EngineStatus,
    bool_from_string = bool_from_string,
    engine_status_path = engine_status_path,
    engines = engines,
    azure_regions = azure_regions,
    log = log,
})
if dd.engine_runtime == nil
    or type(dd.engine_runtime.Refresh) ~= "function"
    or type(dd.engine_runtime.Index) ~= "function"
    or type(dd.engine_runtime.RegionIndex) ~= "function"
    or type(dd.engine_runtime.Current) ~= "function"
    or type(dd.engine_runtime.CurrentLabel) ~= "function" then
    error("MortalShell2TTS Engine.Runtime failed: " .. tostring(dd.engine_runtime_error or "missing API"))
end
diag("dependency.engineRuntime", { module = "Engine.Runtime", ownership = "engine-status-runtime", status = "ready" })

local function refresh_engine_status()
    return dd.engine_runtime.Refresh()
end

dd.voice_runtime, dd.voice_runtime_error = dd.VoiceBrowserRuntimeFactory.New({
    config = config,
    ui = ui,
    read_file = read_file,
    sanitize_text = dd.sanitize_config_text,
    log = log,
    diag = diag,
    voices_path = voices_path,
    azure_voices_path = azure_voices_path,
})
if dd.voice_runtime == nil
    or type(dd.voice_runtime.Refresh) ~= "function"
    or type(dd.voice_runtime.ActiveValue) ~= "function"
    or type(dd.voice_runtime.CurrentRecord) ~= "function"
    or type(dd.voice_runtime.CurrentStyles) ~= "function"
    or type(dd.voice_runtime.CurrentPitchSupported) ~= "function"
    or type(dd.voice_runtime.NormalizedStyle) ~= "function"
    or type(dd.voice_runtime.StyleLabel) ~= "function"
    or type(dd.voice_runtime.CurrentLabel) ~= "function"
    or type(dd.voice_runtime.Index) ~= "function" then
    error("MortalShell2TTS VoiceBrowser.Runtime failed: " .. tostring(dd.voice_runtime_error or "missing API"))
end
diag("dependency.voiceBrowserRuntime", { module = "VoiceBrowser.Runtime", ownership = "voice-catalog-runtime", status = "ready" })

local function active_voice_value()
    return dd.voice_runtime.ActiveValue()
end

local function refresh_voices(force)
    return dd.voice_runtime.Refresh(force)
end

function dd.current_voice_record(value)
    return dd.voice_runtime.CurrentRecord(value)
end

function dd.current_voice_styles(value)
    return dd.voice_runtime.CurrentStyles(value)
end

function dd.current_voice_pitch_supported(value)
    return dd.voice_runtime.CurrentPitchSupported(value)
end

function dd.normalized_voice_style(value)
    return dd.voice_runtime.NormalizedStyle(value)
end

function dd.voice_style_label()
    return dd.voice_runtime.StyleLabel()
end

dd.audio_runtime, dd.audio_runtime_error = dd.AudioRuntimeFactory.New({
    config = config,
    ui = ui,
    read_file = read_file,
    parser = dd.AudioOutputs,
    sanitize_text = dd.sanitize_config_text,
    outputs_path = audio_outputs_path,
    log = log,
})
if dd.audio_runtime == nil
    or type(dd.audio_runtime.Refresh) ~= "function"
    or type(dd.audio_runtime.CurrentLabel) ~= "function"
    or type(dd.audio_runtime.Index) ~= "function" then
    error("MortalShell2TTS Audio.Runtime failed: " .. tostring(dd.audio_runtime_error or "missing API"))
end
diag("dependency.audioRuntime", { module = "Audio.Runtime", ownership = "audio-output-catalog-runtime", status = "ready" })

local function refresh_audio_outputs()
    return dd.audio_runtime.Refresh()
end

local function current_audio_output_label()
    return dd.audio_runtime.CurrentLabel()
end

local function audio_output_index()
    return dd.audio_runtime.Index()
end

local function current_voice_label()
    return dd.voice_runtime.CurrentLabel()
end

local function voice_index()
    return dd.voice_runtime.Index()
end

-- Shared standalone-host analog reader is late-bound after Host.Registry registration.
-- Voice Browser/controller closures can reference it now and automatically begin consuming
-- host-owned samples once the revision/epoch acknowledgement arrives.
local read_modui_host_axis = nil

-- Voice Browser interaction/controller state is module-owned. Native Settings
-- rendering and input-hook registration remain in this host; callbacks are late-bound
-- so the controller cannot acquire those lifetimes during construction.
dd.voice_browser_controller, dd.voice_browser_controller_error = dd.VoiceBrowserControllerFactory.New({
    config = config,
    ui = ui,
    state = dd.voice_browser,
    catalog = dd.VoiceBrowserCatalog,
    repeat_api = dd.ModUI.Input.Repeat,
    refresh_voices = refresh_voices,
    active_voice_value = active_voice_value,
    current_voice_label = current_voice_label,
    save_config = save_config,
    trim = trim,
    log = log,
    diag = diag,
    capture_voice_profile = dd.capture_voice_profile,
    apply_voice_profile = dd.apply_voice_profile,
    current_voice_pitch_supported = dd.current_voice_pitch_supported,
    normalized_voice_style = dd.normalized_voice_style,
    voice_profile = dd.voice_profile,
    default_voice_profile = dd.default_voice_profile,
    sanitize_voice_profile = dd.sanitize_voice_profile,
    tts_command = tts_command,
    redraw = function() if type(dd.set_ui_text) == "function" then dd.set_ui_text() end end,
    apply_window_profile = function(profile) if type(dd.apply_window_profile) == "function" then dd.apply_window_profile(profile) end end,
    reset_open_sequences = function()
        if dd.open_bind_sequence_state ~= nil then
            dd.open_bind_sequence_state.keyboard = nil
            dd.open_bind_sequence_state.controller = nil
        end
    end,
    unwrap = unwrap,
    valid = valid,
    input_key_down = function(controller, key)
        if type(dd.input_key_down) == "function" then return dd.input_key_down(controller, key) end
        return false, "unavailable"
    end,
    input_analog_value = function(controller, key)
        if type(read_modui_host_axis) == "function" then
            local value, source, ready = read_modui_host_axis(tostring(key or ""))
            if ready and tonumber(value) ~= nil then
                return tonumber(value), "ModUIHost:" .. tostring(source or key)
            end
        end
        if type(dd.input_analog_value) == "function" then return dd.input_analog_value(controller, key) end
        return 0, "unavailable"
    end,
    finite_number = function(value) return type(dd.finite_number) == "function" and dd.finite_number(value) or false end,
})
if dd.voice_browser_controller == nil
    or type(dd.voice_browser_controller.Open) ~= "function"
    or type(dd.voice_browser_controller.Close) ~= "function"
    or type(dd.voice_browser_controller.Activate) ~= "function"
    or type(dd.voice_browser_controller.UpdatePoll) ~= "function" then
    error("MortalShell2TTS VoiceBrowser.Controller failed: " .. tostring(dd.voice_browser_controller_error or "missing API"))
end
diag("dependency.voiceBrowserController", { module = "VoiceBrowser.Controller", ownership = "browser-interaction-state", status = "ready" })
function dd.favorite_config_field() return dd.voice_browser_controller.FavoriteField() end
function dd.favorite_voice_set() return dd.voice_browser_controller.FavoriteSet() end
function dd.is_voice_favorite(value) return dd.voice_browser_controller.IsFavorite(value) end
function dd.toggle_voice_favorite(value) return dd.voice_browser_controller.ToggleFavoriteValue(value) end
function dd.voice_browser_rebuild(value) return dd.voice_browser_controller.Rebuild(value) end
function dd.voice_browser_rows() return dd.voice_browser_controller.Rows() end
function dd.voice_browser_current_voice() return dd.voice_browser_controller.CurrentVoice() end
function dd.open_voice_browser() return dd.voice_browser_controller.Open() end
function dd.commit_voice_browser_selection(source) return dd.voice_browser_controller.Commit(source) end
function dd.close_voice_browser(reason) return dd.voice_browser_controller.Close(reason) end
function dd.voice_browser_cycle_gender(delta) return dd.voice_browser_controller.CycleGender(delta) end
function dd.voice_browser_append_search(text, kind, shifted) return dd.voice_browser_controller.AppendSearch(text, kind, shifted) end
function dd.voice_browser_toggle_favorite() return dd.voice_browser_controller.ToggleFavorite() end
function dd.voice_browser_activate() return dd.voice_browser_controller.Activate() end
function dd.voice_browser_move(delta) return dd.voice_browser_controller.Move(delta) end
function dd.voice_browser_page(delta) return dd.voice_browser_controller.Page(delta) end
function dd.voice_browser_jump(which) return dd.voice_browser_controller.Jump(which) end
function dd.voice_browser_page_modifier_down(controller) return dd.voice_browser_controller.PageModifierDown(controller) end
function dd.voice_browser_wheel(delta, source) return dd.voice_browser_controller.Wheel(delta, source) end
function dd.update_voice_browser_poll(controller) return dd.voice_browser_controller.UpdatePoll(controller) end

-- Pass 175: shared controller settings/calibration/test belongs to MortalShell2ModUI.
-- TTS is only one consumer/launcher; Minimap and future providers consume the same profile.
dd.controller_settings, dd.controller_settings_error = dd.ModUI.Controller.Settings.New({
    profile = dd.ModUI.Controller.Profile,
    read_axis = function(key)
        if type(read_modui_host_axis) == "function" then return read_modui_host_axis(tostring(key or "")) end
        if type(dd.read_modui_host_axis) == "function" then return dd.read_modui_host_axis(tostring(key or "")) end
        return nil, "unavailable", false, 0
    end,
    read_key = function(key)
        if type(dd.read_modui_host_key) == "function" then return dd.read_modui_host_key(tostring(key or "")) end
        return false, "unavailable", false, 0
    end,
    set_capture_request = function(kind, active)
        if type(dd.write_modui_host_capture_request) == "function" then return dd.write_modui_host_capture_request(kind, active) end
        return false, "host-capture-writer-unavailable"
    end,
    profile_changed = function(profile, reason)
        if type(dd.publish_modui_controller_profile) == "function" then
            return dd.publish_modui_controller_profile(profile, reason)
        end
        return false, "controller-profile-sync-unavailable"
    end,
    get_selected = function() return ui.selected end,
    set_selected = function(value) ui.selected = math.max(1, math.floor(tonumber(value) or 1)) end,
    set_status = function(value) ui.status = tostring(value or "") end,
    apply_window_profile = function(profile) if type(dd.apply_window_profile) == "function" then dd.apply_window_profile(profile) end end,
    redraw = function() if type(dd.set_ui_text) == "function" then return dd.set_ui_text() end return true end,
    diag = diag, log = log,
})
if dd.controller_settings == nil
    or type(dd.controller_settings.Active) ~= "function"
    or type(dd.controller_settings.Open) ~= "function"
    or type(dd.controller_settings.Back) ~= "function"
    or type(dd.controller_settings.Shutdown) ~= "function"
    or type(dd.controller_settings.Rows) ~= "function"
    or type(dd.controller_settings.Move) ~= "function"
    or type(dd.controller_settings.Change) ~= "function"
    or type(dd.controller_settings.Activate) ~= "function"
    or type(dd.controller_settings.Poll) ~= "function"
    or type(dd.controller_settings.SamplingActive) ~= "function" then
    error("MortalShell2ModUI Controller.Settings failed: " .. tostring(dd.controller_settings_error or "missing API"))
end
function dd.controller_settings_active() return dd.controller_settings.Active() end
function dd.open_controller_settings() return dd.controller_settings.Open() end
function dd.close_controller_settings(reason) return dd.controller_settings.Back(reason) end
function dd.shutdown_controller_settings(reason) return dd.controller_settings.Shutdown(reason) end
function dd.controller_settings_rows() return dd.controller_settings.Rows() end
function dd.controller_settings_move(delta) return dd.controller_settings.Move(delta) end
function dd.controller_settings_change(delta) return dd.controller_settings.Change(delta) end
function dd.controller_settings_activate() return dd.controller_settings.Activate() end
function dd.update_controller_settings_poll() return dd.controller_settings.Poll() end
function dd.controller_settings_sampling_active() return dd.controller_settings.SamplingActive() end
diag("dependency.moduiController", { module = "MortalShell2ModUI.Controller.Settings", ownership = "shared-controller-profile+calibration+test", status = "ready" })

dd.settings_presentation, dd.settings_presentation_error = dd.SettingsPresentationFactory.New({
    config = config,
    ui = ui,
    tabs = tabs,
    descriptions = row_descriptions,
    model = dd.ModUI.Settings.Model,
    render = dd.ModUI.Settings.Render,
    text = dd.ModUI.Text,
    trim = trim,
    valid = valid,
    voice_browser = dd.voice_browser,
    voice_browser_rows = function() return dd.voice_browser_controller.Rows() end,
    controller_settings_active = function() return dd.controller_settings.Active() end,
    controller_settings_rows = function() return dd.controller_settings.Rows() end,
    controller_settings_label = function(row) return dd.controller_settings.Label(row) end,
    controller_settings_value = function(row) return dd.controller_settings.Value(row) end,
    controller_settings_description = function(row) return dd.controller_settings.Description(row) end,
    controller_settings_control_hint = function(row) return dd.controller_settings.ControlHint(row) end,
    controller_settings_header = function() return dd.controller_settings.HeaderText() end,
    controller_settings_tab = function() return dd.controller_settings.TabText() end,
    controller_settings_page = function() return dd.controller_settings.PageText() end,
    bind_capture_active = function(kind) return type(dd.bind_capture_active) == "function" and dd.bind_capture_active(kind) or false end,
    keyboard_open_label = function() return type(dd.keyboard_open_label) == "function" and dd.keyboard_open_label() or "" end,
    controller_open_label = function() return type(dd.controller_open_label) == "function" and dd.controller_open_label() or "" end,
    current_voice_label = current_voice_label,
    voice_style_label = function() return dd.voice_runtime.StyleLabel() end,
    current_voice_pitch_supported = function() return dd.voice_runtime.CurrentPitchSupported() end,
    normalize_queue_behavior = dd.normalize_queue_behavior,
    normalize_duplicate_window = dd.normalize_duplicate_window,
    engine_current_label = function() return dd.engine_runtime.CurrentLabel() end,
    engine_current = function() return dd.engine_runtime.Current() end,
    current_audio_output_label = current_audio_output_label,
    refresh_engine_status = refresh_engine_status,
    is_voice_favorite = function(value) return dd.voice_browser_controller.IsFavorite(value) end,
    binding_conflict_badge = function(kind) return type(dd.binding_conflict_badge) == "function" and dd.binding_conflict_badge(kind) or "" end,
})
if dd.settings_presentation == nil
    or type(dd.settings_presentation.RowValue) ~= "function"
    or type(dd.settings_presentation.RowDisplayLabel) ~= "function"
    or type(dd.settings_presentation.RowDisplayValue) ~= "function"
    or type(dd.settings_presentation.PlainText) ~= "function"
    or type(dd.settings_presentation.Ellipsize) ~= "function" then
    error("MortalShell2TTS Settings.Presentation failed: " .. tostring(dd.settings_presentation_error or "missing API"))
end
diag("dependency.settingsPresentation", { module = "Settings.Presentation", ownership = "settings-view-model-text", status = "ready" })

-- Capturable input catalog. These are Unreal FKey names, not UE4SS RegisterKeyBind
-- enum values. Normal activation polls only the saved chord; the broader catalogs are
-- scanned only for the few seconds while a user is actively recording a new bind.
dd.keyboard_capture_keys = {
    "LeftControl", "RightControl", "LeftShift", "RightShift", "LeftAlt", "RightAlt",
    "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M",
    "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z",
    "Zero", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine",
    "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12",
    "SpaceBar", "Tab", "Enter", "Escape", "BackSpace", "Insert", "Delete", "Home", "End", "PageUp", "PageDown",
    "Up", "Down", "Left", "Right", "CapsLock", "NumLock", "ScrollLock",
    "Semicolon", "Equals", "Comma", "Hyphen", "Period", "Slash", "Tilde",
    "LeftBracket", "Backslash", "RightBracket", "Apostrophe",
    "NumPadZero", "NumPadOne", "NumPadTwo", "NumPadThree", "NumPadFour",
    "NumPadFive", "NumPadSix", "NumPadSeven", "NumPadEight", "NumPadNine",
    "Decimal", "Divide", "Multiply", "Subtract", "Add",
}

dd.controller_capture_keys = {
    "Gamepad_LeftThumbstick", "Gamepad_RightThumbstick",
    "Gamepad_FaceButton_Bottom", "Gamepad_FaceButton_Right", "Gamepad_FaceButton_Left", "Gamepad_FaceButton_Top",
    "Gamepad_LeftShoulder", "Gamepad_RightShoulder",
    "Gamepad_DPad_Up", "Gamepad_DPad_Down", "Gamepad_DPad_Left", "Gamepad_DPad_Right",
    "Gamepad_Special_Left", "Gamepad_Special_Right",
}

dd.controller_capture_axes = {
    { token = "axis:Gamepad_LeftX:neg", key = "Gamepad_LeftX", sign = -1, label = "L Stick Left" },
    { token = "axis:Gamepad_LeftX:pos", key = "Gamepad_LeftX", sign =  1, label = "L Stick Right" },
    { token = "axis:Gamepad_LeftY:pos", key = "Gamepad_LeftY", sign =  1, label = "L Stick Up" },
    { token = "axis:Gamepad_LeftY:neg", key = "Gamepad_LeftY", sign = -1, label = "L Stick Down" },
    { token = "axis:Gamepad_RightX:neg", key = "Gamepad_RightX", sign = -1, label = "R Stick Left" },
    { token = "axis:Gamepad_RightX:pos", key = "Gamepad_RightX", sign =  1, label = "R Stick Right" },
    { token = "axis:Gamepad_RightY:pos", key = "Gamepad_RightY", sign =  1, label = "R Stick Down" },
    { token = "axis:Gamepad_RightY:neg", key = "Gamepad_RightY", sign = -1, label = "R Stick Up" },
    { token = "axis:Gamepad_LeftTriggerAxis:pos", key = "Gamepad_LeftTriggerAxis", sign = 1, label = "L2" },
    { token = "axis:Gamepad_RightTriggerAxis:pos", key = "Gamepad_RightTriggerAxis", sign = 1, label = "R2" },
}

dd.input_labels = dd.ModUI.Input.Binding.Labels
dd.binding_is_sequence = dd.ModUI.Input.Binding.IsSequence
dd.binding_tokens = dd.ModUI.Input.Binding.Tokens

function dd.binding_token_label(token)
    return dd.ModUI.Input.Binding.TokenLabel(token, config.modifier_sides_equivalent)
end

function dd.binding_label(value, fallback)
    return dd.ModUI.Input.Binding.Label(value, fallback, config.modifier_sides_equivalent)
end

function dd.keyboard_open_label()
    return dd.binding_label(config.menu_keybind, "Ctrl + T + T + S")
end

function dd.controller_open_label()
    return dd.binding_label(config.controller_menu_bind, "Unbound")
end

function dd.sync_open_bind_labels()
    if ui ~= nil then ui.menu_key = dd.keyboard_open_label() end
end

function dd.bind_capture_active(kind)
    local state = dd.bind_capture
    if type(state) ~= "table" or state.active ~= true then return false end
    return kind == nil or state.kind == kind
end

-- Settings.Presentation owns ellipsis behavior after Pass 98, but a few native
-- host-only details-panel paths still need that operation. Keep a thin local
-- adapter rather than duplicating presentation policy in the host.
local function ellipsize_text(value, limit)
    return dd.settings_presentation.Ellipsize(value, limit)
end

local function row_value(row) return dd.settings_presentation.RowValue(row) end
local function row_display_label(row) return dd.settings_presentation.RowDisplayLabel(row) end
local function row_display_value(row) return dd.settings_presentation.RowDisplayValue(row) end

local function apply_ui_style()
    -- Immediate-mode renderers read opacity/text size directly from config.
    return true
end

local function settings_tab_text() return dd.settings_presentation.TabText() end
local function settings_label_text() return dd.settings_presentation.LabelsText() end
local function settings_values_text() return dd.settings_presentation.ValuesText() end
local function settings_combined_text() return dd.settings_presentation.CombinedText() end
local function settings_plain_text() return dd.settings_presentation.PlainText() end
-- Pass 170 extracts the remaining coherent Settings interaction/runtime subsystem from
-- the application composition root. UI.SettingsRuntime owns native/fallback presentation,
-- input acquisition/restoration, native/pointer routing, gameplay isolation, semantic fallback,
-- native bridge construction, and SettingsSession wiring; main.lua retains orchestration only.
dd.SettingsRuntimeFactory, dd.settings_runtime_factory_error = dd.load_lua_table_module(
    scripts_dir .. "\\UI\\SettingsRuntime.lua", "UI.SettingsRuntime")
if dd.SettingsRuntimeFactory == nil or type(dd.SettingsRuntimeFactory.Install) ~= "function" then
    error("MortalShell2TTS UI.SettingsRuntime failed to load: " .. tostring(dd.settings_runtime_factory_error or "missing API"))
end
local settings_runtime, settings_runtime_error = dd.SettingsRuntimeFactory.Install({
    dd = dd, ui = ui, config = config, version = VERSION, scripts_dir = scripts_dir,
    shell_reuse_ms = SHELL_REUSE_MS,
    input_cross_source_dedupe_seconds = INPUT_CROSS_SOURCE_DEDUPE_SECONDS,
    schedule_close_finalize = function(delay_ms)
        if schedule_close_finalize == nil then return false end
        return schedule_close_finalize(delay_ms)
    end,
    schedule_shell_cache_expiry = function(delay_ms, token)
        if schedule_shell_cache_expiry == nil then return false end
        return schedule_shell_cache_expiry(delay_ms, token)
    end,
    unwrap = unwrap, valid = valid, object_name = object_name, widget_text = widget_text,
    runtime_diagnostics = runtime_diagnostics, log = log, diag = diag, trim = trim, clamp = clamp,
    save_config = save_config, tts_command = tts_command, stop_speech = stop_speech,
    engines = engines, azure_regions = azure_regions, tabs = tabs,
    row_description = row_description, row_control_hint = row_control_hint,
    current_tab = current_tab, current_rows = current_rows,
    active_voice_value = active_voice_value, refresh_voices = refresh_voices,
    refresh_audio_outputs = refresh_audio_outputs, audio_output_index = audio_output_index,
    voice_index = voice_index, ellipsize_text = ellipsize_text, row_value = row_value,
    settings_tab_text = settings_tab_text, settings_label_text = settings_label_text,
    settings_values_text = settings_values_text, settings_combined_text = settings_combined_text,
    settings_plain_text = settings_plain_text,
    read_modui_host_axis = function(key)
        if type(read_modui_host_axis) == "function" then return read_modui_host_axis(tostring(key or "")) end
        return nil, "unavailable", false, 0
    end,
})
if type(settings_runtime) ~= "table" then
    error("MortalShell2TTS UI.SettingsRuntime failed: " .. tostring(settings_runtime_error or "missing API"))
end
dd.SettingsRuntime = settings_runtime
local note_modal_keybind = settings_runtime.NoteModalKeybind
local active_ui_session_valid = settings_runtime.ActiveUISessionValid
local claim_cross_source_navigation = settings_runtime.ClaimCrossSourceNavigation
local set_ui_text = settings_runtime.SetUIText
local create_native_input_bridge = settings_runtime.CreateNativeInputBridge
diag("dependency.settingsRuntime", {
    module = "UI.SettingsRuntime", ownership = tostring(settings_runtime.ownership), status = "ready",
})
function dd.save_mod_setting(reason) return dd.settings_controller.Save(reason) end
function dd.cycle_voice(delta) return dd.settings_controller.CycleVoice(delta) end
function dd.cycle_voice_style(delta) return dd.settings_controller.CycleVoiceStyle(delta) end
function dd.cycle_queue_behavior(delta) return dd.settings_controller.CycleQueueBehavior(delta) end
function dd.cycle_duplicate_window(delta) return dd.settings_controller.CycleDuplicateWindow(delta) end
function dd.cycle_engine(delta) return dd.settings_controller.CycleEngine(delta) end
function dd.cycle_azure_region(delta) return dd.settings_controller.CycleAzureRegion(delta) end
function dd.cycle_audio_output(delta) return dd.settings_controller.CycleAudioOutput(delta) end

function dd.clear_reset_confirmation(reason) return dd.settings_controller.ClearResetConfirmation(reason) end
function dd.reset_mod_settings() return dd.settings_controller.ResetMod() end
function dd.reset_speech_settings() return dd.settings_controller.ResetSpeech() end
function dd.reset_engine_settings() return dd.settings_controller.ResetEngine() end
function dd.confirm_settings_reset(reset_key) return dd.settings_controller.ConfirmReset(reset_key) end
function dd.change_selected(delta) return dd.settings_controller.ChangeSelected(delta) end
function dd.activate_selected() return dd.settings_controller.ActivateSelected() end

function dd.move_selection(delta) return dd.settings_controller.MoveSelection(delta) end
function dd.change_tab(delta) return dd.settings_controller.ChangeTab(delta) end
function dd.next_tab() return dd.change_tab(1) end
function dd.previous_tab() return dd.change_tab(-1) end

-- Ensure config exists before the helper reads it. Keep only schema/source
-- provenance in diagnostics; raw config values remain outside the share-safe log.
load_config()
diag("config.runtime", {
    action = "loaded",
    source = tostring(dd.config_load_source or "defaults"),
    schema = tonumber(dd.config_loaded_schema) or 1,
    targetSchema = dd.CONFIG_SCHEMA,
})
dd.initialize_voice_profiles(dd.config_loaded_schema)
diag("config.runtime", {
    action = "initialized",
    source = tostring(dd.config_load_source or "defaults"),
    previousSchema = tonumber(dd.config_loaded_schema) or 1,
    schema = dd.CONFIG_SCHEMA,
})
diag("config.runtime", {
    action = "selection",
    engine = tostring(config.engine),
    audioOutputMode = tostring(config.audio_output):lower() == "default" and "default" or "explicit",
    modifierSides = config.modifier_sides_equivalent and "any-side" or "separate",
    pauseWhileMenu = config.pause_game_while_menu_open and "on" or "off",
    pronunciation = config.pronunciation_corrections ~= false and "on" or "off",
})
dd.sync_open_bind_labels()
save_config()

-- Clear anything an old helper might still be saying, then start/reuse the helper.
tts_command("STOP", "")
dd.start_helper("startup")

-- Keep every callback strongly referenced for the lifetime of the mod. This is
-- intentional: UE4SS can invalidate registry refs if callback closures are only
-- held transiently.
_G.MortalShell2TTSRuntime = _G.MortalShell2TTSRuntime or {}
local runtime = _G.MortalShell2TTSRuntime

-- Short-lived game-thread dispatch/scheduling is application-host infrastructure,
-- not TTS domain logic. Pass 101 moves backend selection, one-shot delay fallback,
-- and once-per-label failure suppression into Runtime.Scheduler.
dd.RuntimeSchedulerFactory, dd.runtime_scheduler_factory_error = dd.load_lua_table_module(scripts_dir .. "\\Runtime\\Scheduler.lua", "Runtime.Scheduler")
if dd.RuntimeSchedulerFactory == nil or type(dd.RuntimeSchedulerFactory.New) ~= "function" then
    error("MortalShell2TTS Runtime.Scheduler failed to load: " .. tostring(dd.runtime_scheduler_factory_error or "missing API"))
end

dd.runtime_scheduler, dd.runtime_scheduler_error = dd.RuntimeSchedulerFactory.New({
    runtime = runtime,
    diag = diag,
    log = log,
    perf = dd.perf,
    execute_in_game_thread = function(callback, method)
        if method ~= nil then return ExecuteInGameThread(callback, method) end
        return ExecuteInGameThread(callback)
    end,
    execute_in_game_thread_with_delay = function(delay_ms, callback)
        if type(ExecuteInGameThreadWithDelay) ~= "function" then return nil, "unavailable" end
        return ExecuteInGameThreadWithDelay(delay_ms, callback)
    end,
    execute_with_delay = function(delay_ms, callback)
        if type(ExecuteWithDelay) ~= "function" then return nil, "unavailable" end
        return ExecuteWithDelay(delay_ms, callback)
    end,
    process_event_method = (function()
        local ok, method = pcall(function() return EGameThreadMethod ~= nil and EGameThreadMethod.ProcessEvent or nil end)
        return ok and method or nil
    end)(),
    process_event_available = (function()
        local ok, available = pcall(function() return ProcessEventAvailable end)
        return ok and available or nil
    end)(),
})
if dd.runtime_scheduler == nil
    or type(dd.runtime_scheduler.Dispatch) ~= "function"
    or type(dd.runtime_scheduler.ScheduleOneShot) ~= "function" then
    error("MortalShell2TTS Runtime.Scheduler failed: " .. tostring(dd.runtime_scheduler_error or "missing API"))
end
diag("dependency.runtimeScheduler", { module = "Runtime.Scheduler", ownership = "game-thread-dispatch+one-shot-delay", status = "ready" })

local function dispatch_game_thread(callback, label)
    return dd.runtime_scheduler.Dispatch(callback, label)
end

local function schedule_one_shot_game_thread(delay_ms, game_callback, async_fallback, label)
    return dd.runtime_scheduler.ScheduleOneShot(delay_ms, game_callback, async_fallback, label)
end

-- The profiler's 10 s summary timer. Perf.lua asks for this through the closure given
-- at construction; it exists only from here on, so the startup sync follows it.
function dd.schedule_perf_summary(delay_ms, callback)
    local ok = schedule_one_shot_game_thread(delay_ms, callback, callback, "perf-summary")
    return ok == true
end
dd.sync_perf("startup")

-- v0.9.18 keeps Mortal Shell's generic WBP_InputListener bridge from v0.9.17 and adds death-safe borrowed-prompt retirement.
-- Enhanced Input bridge. The visible lore reader's WBP_IL_ReadText remains
-- disabled, so settings navigation cannot enter TextList/ReadIndex page logic.
log("settings renderer armed; v0.9.18 backend frozen + v0.9.40 visual geometry restored + v0.9.42 exact modal-effect ownership retained + cached text and cross-source input dedupe preserved + controller out-parameter mouse routing + immediate parent-owned close; offscreen widget probes removed")
diag("startup.renderer", {
    version = VERSION,
    visualBaseline = "v0.9.40",
    backendBaseline = "v0.9.18",
    diagnostics = "focused-no-offscreen-widget-probes",
})

-- Pass 91 freezes the native Quit-confirmation investigation after Pass 90 captured
-- the native idle-block race directly through Runtime.NativeState. The extra
-- WBP_ConfirmationPromptBase.UpdateOpenState diagnostic hook was removed because
-- target-game evidence showed it observed the borrowed TTS ReadText shell but not
-- the game's WBP_ConfirmationPrompt_Default_C lifecycle. The passive read-only
-- native-state observer remains available for future triage without mutation.

-- Pass 168 extracts the complete TTS-side standalone-ModUI client/control plane. The
-- composition root now injects game/application callbacks while Runtime.ModUIHostClient owns
-- registration, acknowledgement, primitive menu publications, host input mailboxes, listener
-- requests, and descriptor-revision continuity.
dd.ModUIHostClientFactory, dd.modui_host_client_factory_error = dd.load_lua_table_module(scripts_dir .. "\\Runtime\\ModUIHostClient.lua", "Runtime.ModUIHostClient")
local modui_host_client = nil
local modui_host_client_failure = nil
if dd.ModUIHostClientFactory == nil or type(dd.ModUIHostClientFactory.Install) ~= "function" then
    modui_host_client_failure = "module-unavailable: " .. tostring(dd.modui_host_client_factory_error or "missing API")
else
    local host_client_ok, host_client_result, host_client_error = pcall(dd.ModUIHostClientFactory.Install, {
        dd = dd,
        modui = dd.ModUI,
        ui = ui,
        config = config,
        runtime = runtime,
        tabs = tabs,
        version = VERSION,
        mod_ref = ModRef,
        unwrap = unwrap,
        valid = valid,
        current_tab = current_tab,
        current_rows = current_rows,
        settings_tab_text = settings_tab_text,
        settings_label_text = settings_label_text,
        settings_values_text = settings_values_text,
        settings_plain_text = settings_plain_text,
        set_ui_text = set_ui_text,
        create_native_input_bridge = create_native_input_bridge,
        diag = diag,
        dispatch_game_thread = dispatch_game_thread,
        schedule_one_shot_game_thread = schedule_one_shot_game_thread,
    })
    if host_client_ok and type(host_client_result) == "table" then
        modui_host_client = host_client_result
        dd.ModUIHostClient = host_client_result
        read_modui_host_axis = host_client_result.ReadAxis
        diag("dependency.moduiHostClient", {
            module = "Runtime.ModUIHostClient", ownership = tostring(host_client_result.ownership),
            registrationReady = host_client_result.RegistrationReady(), status = "ready",
        })
    else
        modui_host_client_failure = tostring(host_client_ok and host_client_error or host_client_result)
    end
end
if modui_host_client == nil then
    diag("dependency.moduiHostClient", {
        module = "Runtime.ModUIHostClient", failure = tostring(modui_host_client_failure),
        status = "unavailable-consumer-input-fallback",
    })
end


-- Pass 119 keeps Runtime.InputHost as the consumer semantic runtime but routes healthy
-- non-pointer WBP_InputListener menu events from the acknowledged standalone native-hook ring.
-- Mouse/pointer semantics remain immediate/local until cursor-at-event data is host-owned.
-- Pass 113 keeps all controller analog axes on the acknowledged standalone poll whenever its
-- revision/epoch-bound mailbox is healthy. Pass 108 delegates OPEN-HOTKEY physical reads.
-- hostSinglePhysicalInput remains false because pointer/native-listener construction is not yet centralized.
-- Pass 105 transfers the reusable consumer-scoped open-hotkey / physical input /
-- recorder runtime into MortalShell2ModUI Runtime.InputHost. This fixes code ownership
-- without pretending the future cross-Lua-state ONE physical host already exists.
-- Pass-104 fail-soft isolation remains: failure of this Settings/input capability must
-- never prevent the independent lore-reader hooks from arming.
local input_runtime_ready = false
local input_runtime_failure = nil
local InputRuntimeFactory = dd.ModUI ~= nil and dd.ModUI.Runtime ~= nil and dd.ModUI.Runtime.InputHost or nil
if type(InputRuntimeFactory) ~= "table" or type(InputRuntimeFactory.Install) ~= "function" then
    input_runtime_failure = "modui-input-host-unavailable: " .. tostring(dd.ModUI ~= nil and dd.ModUI.Runtime ~= nil and dd.ModUI.Runtime.InputHostError or "missing")
else
        -- UE4SS exposes several engine helpers as callable host objects whose Lua `type()`
        -- is not guaranteed to be `function` across runtime builds. Pass 103 forwarded FName
        -- directly and Input.Runtime then rejected anything whose type was not exactly function.
        -- Keep host-specific callable identity at the composition boundary and inject ordinary
        -- Lua closures instead. Any eventual call is still protected by the owning operation.
        local input_fname_adapter = function(value)
            return FName(value)
        end
        local input_delay_adapter = nil
        if ExecuteInGameThreadWithDelay ~= nil then
            input_delay_adapter = function(delay_ms, callback)
                return ExecuteInGameThreadWithDelay(delay_ms, callback)
            end
        end
        local input_keybind_registered_adapter = nil
        if IsKeyBindRegistered ~= nil then
            input_keybind_registered_adapter = function(...)
                return IsKeyBindRegistered(...)
            end
        end

        local install_ok, input_runtime, input_runtime_error = pcall(InputRuntimeFactory.Install, {
            dd = dd,
            modui = dd.ModUI,
            consumer_menu_label = "MortalShell2TTS menu",
            consumer_conflict_source_id = "tts-menu",
            ui = ui,
            config = config,
            runtime = runtime,
            unwrap = unwrap,
            valid = valid,
            object_name = object_name,
            object_address = dd.native_ui_runtime.ObjectAddress,
            text_string = text_string,
            trim = trim,
            bool_from_string = bool_from_string,
            parent_path = parent_path,
            mod_dir = mod_dir,
            file_exists = file_exists,
            read_file = read_file,
            get_player_and_controller = dd.native_presentation.GetPlayerAndController,
            open_context_admission = function(controller)
                -- Only true non-gameplay contexts belong here. Transition/quiescence denial is
                -- intentionally separate so Runtime.InputHost can retain one fresh open intent.
                return dd.evaluate_gameplay_controller_context(controller)
            end,
            transition_context_admission = function(controller)
                -- Pass 170: queue a fresh hotkey edge observed while the incoming controller is
                -- valid but TTS's deeper transition cooldown is still active. InputHost dispatches
                -- it only after every settle/quiescence gate clears and the binding is released.
                return dd.evaluate_transition_settle_admission(controller)
            end,
            active_ui_session_valid = active_ui_session_valid,
            set_ui_text = set_ui_text,
            diag = diag,
            log = log,
            execute_in_game_thread_with_delay = input_delay_adapter,
            fname = input_fname_adapter,
            is_keybind_registered = input_keybind_registered_adapter,
            global_table = _G,
            host_event_reader = modui_host_client ~= nil and modui_host_client.ReadEvent or nil,
            host_navigation_reader = dd.read_modui_host_navigation_events,
            host_native_input_reader = dd.read_modui_host_native_input_events,
            host_native_input_dispatch = dd.dispatch_modui_host_native_input_event,
            host_axis_reader = read_modui_host_axis,
            host_key_reader = dd.read_modui_host_key,
            host_capture_request_writer = dd.write_modui_host_capture_request,
            controller_profile_revision_reader = dd.read_modui_controller_profile_revision,
            on_binding_changed = dd.republish_modui_host_binding,
            on_open_transition_ready = function(reason)
                if modui_host_client == nil or type(dd.republish_modui_host_binding) ~= "function" then
                    return false
                end
                if modui_host_client.consumerOpenHotkeyIsolation == true
                    or runtime.modui_host_hotkey_transition_quarantined ~= true then
                    return true
                end
                runtime.modui_host_hotkey_transition_quarantined = false
                local enable_ok, enable_result = pcall(
                    dd.republish_modui_host_binding, "transition-hotkey-enable", config.menu_keybind)
                local enabled = enable_ok and enable_result ~= false
                diag("input.hostOpenHotkeyTransition", {
                    status = enabled and "host-enable-republished" or "host-enable-failed-consumer-fallback",
                    reason = tostring(reason or "transition-settled"),
                })
                if not enabled then
                    runtime.modui_host_hotkey_transition_quarantined = true
                end
                return enabled
            end,
            on_shell_cache_discard = function(generation, shell_address, cache_token, reason)
                if type(dd.publish_modui_host_menu_shell) ~= "function" then return false end
                return dd.publish_modui_host_menu_shell("retired", generation,
                    tostring(shell_address or ""), false, tonumber(cache_token) or 0,
                    "controller-world-break:" .. tostring(reason or "unknown"))
            end,
        })
        if not install_ok then
            input_runtime_failure = "install-exception: " .. tostring(input_runtime)
        elseif input_runtime == nil then
            input_runtime_failure = "install-rejected: " .. tostring(input_runtime_error)
        else
            dd.InputRuntime = input_runtime
            input_runtime_ready = true
            diag("dependency.inputRuntime", {
                module = "MortalShell2ModUI.Runtime.InputHost",
                ownership = tostring(input_runtime.ownership),
                captureTransactional = input_runtime.captureTransactional,
                callableAdapters = true,
                consumerScoped = true,
                hostEventDelegation = input_runtime.hostEventDelegation == true,
                hostNavigationDelegation = input_runtime.hostNavigationDelegation == true,
                hostNativeInputMirrorDelegation = input_runtime.hostNativeInputMirrorDelegation == true,
                hostNativeInputSemanticDelegation = input_runtime.hostNativeInputSemanticDelegation == true,
                hostAnalogDelegation = input_runtime.hostAnalogDelegation == true,
                hostControllerCaptureDelegation = input_runtime.hostControllerCaptureDelegation == true,
                bindingChangeDelegation = input_runtime.bindingChangeDelegation == true,
                loadMapTransitionFreeze = input_runtime.loadMapTransitionFreeze == true,
                loadMapResumeDelayMs = input_runtime.loadMapResumeDelayMs,
                transitionPendingOpenIntent = input_runtime.transitionPendingOpenIntent == true,
                transitionIntentPollCadenceMs = input_runtime.transitionIntentPollCadenceMs,
                physicalOpenHotkeyHost = runtime.modui_host_hotkey_ready == true,
                physicalRightStickYHost = runtime.modui_host_right_y_ready == true,
                physicalControllerAnalogHost = runtime.modui_host_controller_analog_ready == true,
                physicalControllerCaptureHost = runtime.modui_host_controller_capture_ready,
                physicalNativeInputHookHost = runtime.modui_host_native_input_hook_ready,
                physicalNativeListenerShadowHost = runtime.modui_host_native_listener_shadow_ready,
                singlePhysicalHost = false,
                status = "ready",
            })
        end
end

if not input_runtime_ready then
    -- Input/hotkey hosting is a Settings capability; it must never be a prerequisite for
    -- event-driven lore narration. Pass 103 returned from main.lua here and therefore
    -- prevented reader-hook registration too. Fail this subsystem closed, report it, and
    -- continue core startup so a future input-host defect cannot silently disable TTS.
    log("MortalShell2ModUI Runtime.InputHost unavailable; Settings open/capture input is disabled but core lore narration will continue: " .. tostring(input_runtime_failure))
    diag("dependency.inputRuntime", {
        module = "MortalShell2ModUI.Runtime.InputHost",
        ownership = "shared-consumer-input-host",
        failure = tostring(input_runtime_failure),
        status = "unavailable-core-continues",
    })
end


local function cancel_runtime_handle(field)
    local handle = runtime[field]
    if handle ~= nil and type(CancelDelayedAction) == "function" then
        local ok, result = pcall(CancelDelayedAction, handle)
        diag("delay.cancel", {
            field = field,
            handle = tostring(handle),
            callOk = ok,
            cancelRequestFound = ok and tostring(result) or "<error>",
            error = ok and nil or result,
        })
    elseif handle ~= nil then
        diag("delay.cancel", {
            field = field,
            handle = tostring(handle),
            callOk = false,
            error = "CancelDelayedAction unavailable",
        })
    end
    runtime[field] = nil
end

runtime.speech_delay_game = function()
    local old_handle = runtime.speech_delay_handle
    runtime.speech_delay_handle = nil
    diag("delay.callback", {
        label = "speech-delay",
        stage = "enter",
        priorHandle = old_handle ~= nil and tostring(old_handle) or "<nil>",
        pendingSpeech = dd.speech_queue.HasPending(),
    })
    process_pending_speech()
    diag("delay.callback", {
        label = "speech-delay",
        stage = "exit",
        pendingSpeech = dd.speech_queue.HasPending(),
    })
end
runtime.speech_delay_async = function()
    diag("delay.callback", { label = "speech-delay", stage = "legacy-async-wake" })
    dispatch_game_thread(runtime.speech_delay_game, "speech-delay")
end

schedule_pending_speech = function(delay_ms)
    cancel_runtime_handle("speech_delay_handle")
    local ok, handle = schedule_one_shot_game_thread(delay_ms, runtime.speech_delay_game, runtime.speech_delay_async, "speech-delay")
    if ok then runtime.speech_delay_handle = handle end
    return ok
end

schedule_close_finalize = function(delay_ms)
    cancel_runtime_handle("ui_close_handle")
    local generation = tonumber(ui.close_generation) or 0
    if generation <= 0 then
        diag("delay.schedule", { label = "close-finalize", stage = "rejected", reason = "generation-unavailable" })
        return false
    end

    runtime.ui_close_callbacks = runtime.ui_close_callbacks or {}
    local game_callback = nil
    game_callback = function()
        local old_handle = runtime.ui_close_handle
        runtime.ui_close_handle = nil
        runtime.ui_close_callbacks[generation] = nil
        local generation_matches = ui.closing
            and tonumber(ui.active_generation) == generation
            and tonumber(ui.close_generation) == generation
        diag("delay.callback", {
            label = "close-finalize",
            stage = "enter",
            priorHandle = old_handle ~= nil and tostring(old_handle) or "<nil>",
            closing = ui.closing,
            reason = ui.close_reason,
            expectedGeneration = generation,
            activeGeneration = ui.active_generation,
            closeGeneration = ui.close_generation,
            generationMatches = generation_matches,
        })
        if not generation_matches then
            diag("delay.callback", {
                label = "close-finalize",
                stage = "generation-guard-skip",
                expectedGeneration = generation,
                activeGeneration = ui.active_generation,
                closeGeneration = ui.close_generation,
            })
            return
        end
        local reason = ui.close_reason or "settings close"
        if type(dd.SettingsSession) == "table" and type(dd.SettingsSession.Destroy) == "function" then
            dd.SettingsSession.Destroy(reason)
        else
            diag("dependency.settingsSession", { status = "close-finalize-unavailable", reason = reason })
        end
        log("settings UI closed after close quarantine generation=" .. tostring(generation))
        diag("delay.callback", { label = "close-finalize", stage = "exit", reason = reason, generation = generation })
    end
    local async_callback = function()
        diag("delay.callback", { label = "close-finalize", stage = "legacy-async-wake", generation = generation })
        dispatch_game_thread(game_callback, "close-finalize-g" .. tostring(generation))
    end
    runtime.ui_close_callbacks[generation] = {
        game = game_callback,
        async = async_callback,
    }
    local ok, handle = schedule_one_shot_game_thread(
        delay_ms,
        game_callback,
        async_callback,
        "close-finalize-g" .. tostring(generation)
    )
    if ok then runtime.ui_close_handle = handle end
    if not ok then runtime.ui_close_callbacks[generation] = nil end
    return ok
end

schedule_shell_cache_expiry = function(delay_ms, token)
    token = tonumber(token)
    if token == nil then return false end

    runtime.ui_shell_cache_callbacks = runtime.ui_shell_cache_callbacks or {}
    local game_callback = nil
    game_callback = function()
        runtime.ui_shell_cache_callbacks[token] = nil
        if type(dd.SettingsSession) == "table" and type(dd.SettingsSession.ExpireCachedShell) == "function" then
            dd.SettingsSession.ExpireCachedShell(token, "reuse-window-expired")
        end
    end
    local async_callback = function()
        dispatch_game_thread(game_callback, "shell-cache-expire-t" .. tostring(token))
    end
    runtime.ui_shell_cache_callbacks[token] = {
        game = game_callback,
        async = async_callback,
    }
    local ok = schedule_one_shot_game_thread(
        delay_ms,
        game_callback,
        async_callback,
        "shell-cache-expire-t" .. tostring(token)
    )
    if not ok then runtime.ui_shell_cache_callbacks[token] = nil end
    return ok
end

-- Exact reader hooks replace the old permanent 150 ms watcher. Blueprint hooks
-- run when Mortal Shell II actually changes/opens/closes the reader, so there is
-- no idle Lua callback for UE4SS's EngineTick registry GC to invalidate.
runtime.reader_content_handler = function(Context)
    handle_reader_content_event(Context, "content")
end
runtime.reader_page_handler = function(Context)
    handle_reader_content_event(Context, "page")
end
runtime.reader_close_handler = function(Context)
    handle_reader_close_event(Context, "close")
end

runtime.reader_content_callback = runtime.reader_content_callback or function(...)
    local current = _G.MortalShell2TTSRuntime
    if current ~= nil and current.reader_content_handler ~= nil then
        return current.reader_content_handler(...)
    end
end
runtime.reader_page_callback = runtime.reader_page_callback or function(...)
    local current = _G.MortalShell2TTSRuntime
    if current ~= nil and current.reader_page_handler ~= nil then
        return current.reader_page_handler(...)
    end
end
runtime.reader_close_callback = runtime.reader_close_callback or function(...)
    local current = _G.MortalShell2TTSRuntime
    if current ~= nil and current.reader_close_handler ~= nil then
        return current.reader_close_handler(...)
    end
end

runtime.reader_hook_ids = runtime.reader_hook_ids or {}
runtime.register_reader_hooks_game = function()
    local widget_class = dd.native_presentation.LoadNativeSettingsClass()
    if not valid(widget_class) then
        log("reader lifecycle hooks unavailable: lore-reader class could not be loaded")
        return false
    end

    local specs = {
        { dd.ReaderHookPaths.InitMultiText, runtime.reader_content_callback, "InitMultiText" },
        { dd.ReaderHookPaths.SetReadText, runtime.reader_content_callback, "SetReadText" },
        { dd.ReaderHookPaths.ChangePage, runtime.reader_page_callback, "ChangePage" },
        { dd.ReaderHookPaths.PreFadeOutEvent, runtime.reader_close_callback, "PreFadeOutEvent" },
        { dd.ReaderHookPaths.OnMenuClose, runtime.reader_close_callback, "OnMenuClose" },
    }

    local registered = 0
    for _, spec in ipairs(specs) do
        local path, callback, label = spec[1], spec[2], spec[3]
        if runtime.reader_hook_ids[path] ~= nil then
            registered = registered + 1
        else
            local section = "hook.reader." .. tostring(label)
            local handler = callback
            local ok, pre_id, post_id = pcall(RegisterHook, path, function(...)
                local token = dd.perf.Begin()
                handler(...)
                dd.perf.End(section, token)
            end)
            if ok then
                runtime.reader_hook_ids[path] = { pre_id, post_id }
                registered = registered + 1
                log("reader lifecycle hook registered: " .. label)
            else
                log("reader lifecycle hook registration failed: " .. label .. ": " .. tostring(pre_id))
            end
        end
    end

    log("reader lifecycle hooks ready=" .. tostring(registered) .. "/" .. tostring(#specs))
    return registered > 0
end

-- Pass 143 explicit map-lifecycle freeze. UE4SS documents these callbacks as firing before
-- and after UEngine::LoadMap. Keep the closures strongly referenced in the process-lifetime
-- runtime table. Prehook freezes every scheduled consumer input tick before Unreal invalidates
-- the old PlayerController; posthook only arms a primitive delayed resume.
runtime.load_map_pre_callback = function()
    -- Pass 146: clear every observer-owned world wrapper before Unreal begins teardown.
    -- This is assignment/Lua-table work only; the old handler is never validated here.
    if type(dd.reset_native_ui_observer_world_scope) == "function" then
        local ok_observer, observer_err = pcall(dd.reset_native_ui_observer_world_scope, "UEngine.LoadMap-pre")
        if not ok_observer then
            diag("nativeUI.observer", { status = "world-scope-reset-error", error = tostring(observer_err) })
        end
    end

    if type(dd.note_load_map_pre) == "function" then
        local ok_pre, pre_err = pcall(dd.note_load_map_pre, "UEngine.LoadMap-pre")
        if not ok_pre then
            diag("input.loadMapTransition", { status = "pre-callback-error", error = tostring(pre_err) })
        end
    end

    if ui.open or ui.closing then
        local close_function = type(dd.SettingsSession) == "table" and dd.SettingsSession.Destroy or nil
        local ok_close, close_err = false, "settings session destroy unavailable"
        if type(close_function) == "function" then
            ok_close, close_err = pcall(close_function, "load-map-pre-active-session")
        end
        if not ok_close then
            -- Do not attempt a second old-world UObject teardown after an exception. The input
            -- poll remains frozen and the new world will start from cleared primitive ownership.
            diag("session.loadMapRetire", { status = "immediate-close-error", error = tostring(close_err) })
            ui.open = false
            ui.closing = false
        else
            diag("session.loadMapRetire", { status = "immediate-closed-before-unload" })
        end
    end

    -- A LoadMap boundary is also the final primitive-only orphan-session fuse. Do not
    -- carry an `opening`/`ready` consumer session into a new provider revision when the
    -- local UI no longer owns it. No old-world UObject is read or validated here.
    if tostring(runtime.modui_host_menu_session_state or "closed") ~= "closed" then
        local orphan_generation = math.max(
            tonumber(runtime.modui_host_menu_session_generation) or 0,
            tonumber(ui.session_generation) or 0)
        if type(dd.publish_modui_host_menu_shell) == "function" then
            pcall(dd.publish_modui_host_menu_shell, "retired", orphan_generation,
                "", false, 0, "load-map-pre-orphan-session")
        end
        if type(dd.publish_modui_host_menu_session) == "function" then
            pcall(dd.publish_modui_host_menu_session, "closed", orphan_generation,
                "load-map-pre-orphan-session")
        end
        diag("session.loadMapRetire", {
            status = "orphan-session-closed", generation = orphan_generation,
        })
    end

    -- Pass 154 checkpoint-4 safety boundary. Disable standalone physical hotkey polling before
    -- Unreal tears down the old world. This republish is primitive/shared-registry work only.
    -- Runtime.InputHost remains frozen and owns consumer fallback until its existing controller
    -- identity + post-load quiescence gate explicitly re-enables the host in the new world.
    if not (modui_host_client ~= nil and modui_host_client.consumerOpenHotkeyIsolation == true)
        and runtime.modui_host_hotkey_transition_quarantined ~= true
        and type(dd.republish_modui_host_binding) == "function" then
        runtime.modui_host_hotkey_transition_quarantined = true
        local quarantine_ok, quarantine_result = pcall(
            dd.republish_modui_host_binding, "load-map-hotkey-quarantine", config.menu_keybind)
        diag("input.hostOpenHotkeyTransition", {
            status = quarantine_ok and quarantine_result ~= false
                and "loadmap-quarantined" or "loadmap-quarantine-republish-failed",
            reason = "UEngine.LoadMap-pre",
        })
    end
end

runtime.load_map_post_callback = function()
    if type(dd.note_load_map_post) == "function" then
        local ok_post, post_result = pcall(dd.note_load_map_post, "UEngine.LoadMap-post")
        if not ok_post then
            diag("input.loadMapTransition", { status = "post-callback-error", error = tostring(post_result) })
        end
    end
end

runtime.load_map_hooks_registered = false
if type(RegisterLoadMapPreHook) == "function" and type(RegisterLoadMapPostHook) == "function" then
    local pre_ok, pre_err = pcall(RegisterLoadMapPreHook, runtime.load_map_pre_callback)
    local post_ok, post_err = pcall(RegisterLoadMapPostHook, runtime.load_map_post_callback)
    runtime.load_map_hooks_registered = pre_ok and post_ok
    diag("dependency.loadMapTransitionHooks", {
        status = runtime.load_map_hooks_registered and "ready" or "registration-failed",
        preHook = pre_ok, postHook = post_ok, preError = pre_ok and nil or pre_err,
        postError = post_ok and nil or post_err, resumeDelayMs = 1500,
    })
else
    diag("dependency.loadMapTransitionHooks", { status = "unavailable-fail-closed" })
end

runtime.ui_toggle_game = function(source) return dd.toggle_settings_ui(source) end
runtime.ui_up_game = function() dd.move_selection(-1) end
runtime.ui_down_game = function() dd.move_selection(1) end
runtime.ui_left_game = function() dd.change_selected(-1) end
runtime.ui_right_game = function() dd.change_selected(1) end
runtime.ui_return_game = function() dd.activate_selected() end
runtime.ui_tab_game = function() dd.next_tab() end
runtime.ui_prev_tab_game = function() dd.previous_tab() end
runtime.ui_controller_back_game = function()
    if dd.bind_capture_active ~= nil and dd.bind_capture_active() then
        diag("input.controller.dispatch", { status = "back-suppressed-for-bind-recorder", route = "back" })
    elseif dd.controller_settings_active ~= nil and dd.controller_settings_active() then
        dd.close_controller_settings("controller back")
    elseif dd.voice_browser_active ~= nil and dd.voice_browser_active() then
        dd.close_voice_browser("controller back")
    elseif ui.open and not ui.closing and type(dd.SettingsSession) == "table"
        and type(dd.SettingsSession.RequestClose) == "function" then
        dd.SettingsSession.RequestClose("controller back")
    end
end
runtime.ui_pointer_back_game = function()
    if dd.bind_capture_active ~= nil and dd.bind_capture_active() then
        dd.cancel_bind_capture("mouse right-click")
    elseif dd.controller_settings_active ~= nil and dd.controller_settings_active() then
        dd.close_controller_settings("mouse right-click")
    elseif dd.voice_browser_active ~= nil and dd.voice_browser_active() then
        dd.close_voice_browser("mouse right-click")
    elseif ui.open and not ui.closing and type(dd.SettingsSession) == "table"
        and type(dd.SettingsSession.RequestClose) == "function" then
        dd.SettingsSession.RequestClose("mouse right-click")
    end
end
runtime.ui_close_game = function()
    if dd.bind_capture_active ~= nil and dd.bind_capture_active() then
        dd.cancel_bind_capture("Escape")
    elseif dd.controller_settings_active ~= nil and dd.controller_settings_active() then
        dd.close_controller_settings("Escape")
    elseif dd.voice_browser_active ~= nil and dd.voice_browser.active then
        dd.close_voice_browser("Escape")
    elseif ui.open and not ui.closing and type(dd.SettingsSession) == "table"
        and type(dd.SettingsSession.RequestClose) == "function" then
        dd.SettingsSession.RequestClose("Esc")
    end
end


runtime.ui_open_key_candidate = function(binding_id, label)
    if tostring(config.menu_keybind) ~= tostring(binding_id) then return end
    label = tostring(label or binding_id)
    diag("input.keyboard", { action = "toggle", source = label, binding = binding_id, open = ui.open, closing = ui.closing })
    log(label .. " keybind callback fired")
    if ui.closing then return end
    if ui.open then note_modal_keybind("keyboard", "toggle") end
    dispatch_game_thread(function() runtime.ui_toggle_game("keyboard") end, "toggle")
end
runtime.ui_up_key = function()
    if ui.open and not ui.closing and not (dd.bind_capture_active ~= nil and dd.bind_capture_active()) then
        diag("input.keyboard", { action = "up", source = "UpArrow" })
        -- RegisterKeyBind and WBP_InputListener can both observe the same physical
        -- arrow-key press. IsUsingGamepadForFeedback may transiently remain true after
        -- controller use, causing the keyboard-generated IA_Menu_Up to be mistaken for
        -- a controller event. Put the direct keyboard path in the existing cross-source
        -- claim domain so whichever callback arrives first wins; same-source keyboard
        -- repeat is intentionally unaffected by ClaimCrossSource.
        if not claim_cross_source_navigation("up", "keyboard", "UpArrow") then
            return
        end
        if dd.voice_browser_active ~= nil and dd.voice_browser_active() then
            diag("voice.browser.input", { action = "row", direction = "up", source = "keyboard" })
        end
        note_modal_keybind("keyboard", "up")
        dispatch_game_thread(runtime.ui_up_game, "up")
    end
end
runtime.ui_down_key = function()
    if ui.open and not ui.closing and not (dd.bind_capture_active ~= nil and dd.bind_capture_active()) then
        diag("input.keyboard", { action = "down", source = "DownArrow" })
        -- See ui_up_key: this prevents one DownArrow tap from being applied once by
        -- RegisterKeyBind and again by the native IA_Menu_Down bridge when gamepad
        -- feedback mode is transiently stale.
        if not claim_cross_source_navigation("down", "keyboard", "DownArrow") then
            return
        end
        if dd.voice_browser_active ~= nil and dd.voice_browser_active() then
            diag("voice.browser.input", { action = "row", direction = "down", source = "keyboard" })
        end
        note_modal_keybind("keyboard", "down")
        dispatch_game_thread(runtime.ui_down_game, "down")
    end
end
runtime.ui_left_key = function()
    if ui.open and not ui.closing and not (dd.bind_capture_active ~= nil and dd.bind_capture_active()) then
        diag("input.keyboard", { action = "left", source = "LeftArrow" })
        -- Pass 70 extends the Pass-69 primary-arrow protection to value changes.
        -- RegisterKeyBind and WBP_InputListener may both observe one physical LeftArrow;
        -- whichever keyboard/native path arrives first owns the semantic action.
        if not claim_cross_source_navigation("left", "keyboard", "LeftArrow") then
            return
        end
        note_modal_keybind("keyboard", "left")
        dispatch_game_thread(runtime.ui_left_game, "left")
    end
end
runtime.ui_right_key = function()
    if ui.open and not ui.closing and not (dd.bind_capture_active ~= nil and dd.bind_capture_active()) then
        diag("input.keyboard", { action = "right", source = "RightArrow" })
        if not claim_cross_source_navigation("right", "keyboard", "RightArrow") then
            return
        end
        note_modal_keybind("keyboard", "right")
        dispatch_game_thread(runtime.ui_right_game, "right")
    end
end
runtime.ui_return_key = function()
    if ui.open and not ui.closing and not (dd.bind_capture_active ~= nil and dd.bind_capture_active()) then
        diag("input.keyboard", { action = "confirm", source = "Return" })
        note_modal_keybind("keyboard", "confirm")
        dispatch_game_thread(runtime.ui_return_game, "return")
    end
end
runtime.ui_tab_key = function()
    if ui.open and not ui.closing and not (dd.bind_capture_active ~= nil and dd.bind_capture_active()) then
        if dd.voice_browser_active ~= nil and dd.voice_browser_active() then
            diag("input.keyboard", { action = "voice-favorite", source = "Tab" })
            dispatch_game_thread(dd.voice_browser_toggle_favorite, "voice-favorite")
            return
        end
        diag("input.keyboard", { action = "next-tab", source = "Tab" })
        note_modal_keybind("keyboard", "next-tab")
        dispatch_game_thread(runtime.ui_tab_game, "next-tab")
    end
end
runtime.ui_a_key = function()
    if ui.open and not ui.closing and not (dd.bind_capture_active ~= nil and dd.bind_capture_active()) then
        if dd.voice_browser_active ~= nil and dd.voice_browser_active() then
            return
        end
        diag("input.keyboard", { action = "previous-tab", source = "A" })
        note_modal_keybind("keyboard", "previous-tab")
        dispatch_game_thread(runtime.ui_prev_tab_game, "previous-tab")
    end
end
runtime.ui_d_key = function()
    if ui.open and not ui.closing and not (dd.bind_capture_active ~= nil and dd.bind_capture_active()) then
        if dd.voice_browser_active ~= nil and dd.voice_browser_active() then
            return
        end
        diag("input.keyboard", { action = "next-tab", source = "D" })
        note_modal_keybind("keyboard", "next-tab")
        dispatch_game_thread(runtime.ui_tab_game, "next-tab")
    end
end
runtime.ui_page_up_key = function()
    if ui.open and not ui.closing and not (dd.bind_capture_active ~= nil and dd.bind_capture_active()) then
        if dd.voice_browser_active ~= nil and dd.voice_browser.active then
            diag("voice.browser.input", { action = "page", direction = "up", source = "keyboard-page-key", phase = "initial" })
            dispatch_game_thread(function() dd.voice_browser_page(-1) end, "voice-page-up")
            return
        end
        diag("input.keyboard", { action = "details-page-up", source = "PageUp" })
        note_modal_keybind("keyboard", "details-page-up")
        dispatch_game_thread(function() dd.scroll_details(-5, "PageUp") end, "details-page-up")
    end
end
runtime.ui_page_down_key = function()
    if ui.open and not ui.closing and not (dd.bind_capture_active ~= nil and dd.bind_capture_active()) then
        if dd.voice_browser_active ~= nil and dd.voice_browser.active then
            diag("voice.browser.input", { action = "page", direction = "down", source = "keyboard-page-key", phase = "initial" })
            dispatch_game_thread(function() dd.voice_browser_page(1) end, "voice-page-down")
            return
        end
        diag("input.keyboard", { action = "details-page-down", source = "PageDown" })
        note_modal_keybind("keyboard", "details-page-down")
        dispatch_game_thread(function() dd.scroll_details(5, "PageDown") end, "details-page-down")
    end
end
-- v0.9.262: ModUI 0.70.0 publishes "reset-row" after R / L3 has been held 5 s over a
-- row. Restores that row's default only; the tab's Reset rows are untouched.
runtime.ui_reset_row_game = function(source)
    if type(dd.settings_controller) == "table" and type(dd.settings_controller.ResetSelected) == "function" then
        return dd.settings_controller.ResetSelected(source)
    end
    return false
end
runtime.ui_reset_row_key = function()
    if ui.open and not ui.closing and not (dd.bind_capture_active ~= nil and dd.bind_capture_active()) then
        diag("input.keyboard", { action = "reset-row", source = "hold" })
        note_modal_keybind("keyboard", "reset-row")
        dispatch_game_thread(function() runtime.ui_reset_row_game("hold") end, "reset-row")
    end
end
runtime.ui_escape_key = function()
    if ui.open and not ui.closing then
        if dd.bind_capture_active ~= nil and dd.bind_capture_active() then
            -- Do not cancel on key-down. The recorder may still observe another key and
            -- legitimately save Shift+Escape / Ctrl+Escape. Escape alone cancels when the
            -- recorded chord is released.
            diag("input.keyboard", { action = "escape-suppressed-for-bind-recorder", source = "Escape" })
            return
        end
        diag("input.keyboard", { action = "close", source = "Escape" })
        log("Esc keybind callback fired; dispatching quarantined close")
        note_modal_keybind("keyboard", "close")
        dispatch_game_thread(runtime.ui_close_game, "close")
    end
end


-- One startup game-thread handoff is enough to load the cooked reader class and
-- register its lifecycle hooks. No recurring LoopAsync/EngineTick callback is
-- created by MortalShell2TTS v0.9.11.
dispatch_game_thread(runtime.register_reader_hooks_game, "reader-lifecycle-hooks")


-- v0.9.71 keeps the recorded-bind/neutral-gate input path and adds a modal voice browser
-- inside the retained settings shell. Browser search/favorites/gender filtering reuse the
-- existing 50 ms input poll; no additional permanent EngineTick/LoopAsync watcher is added.
-- It still does not register a preset pool for the open shortcut. The saved
-- keyboard/controller chords are read directly through PlayerController input state,
-- which is what makes arbitrary recorded combinations possible without restarting.
runtime.local_keyboard_navigation_registered = false
runtime.register_local_keyboard_navigation_fallback = function(reason)
    if runtime.local_keyboard_navigation_registered or runtime.modui_host_keyboard_navigation_ready then
        return false
    end
    local function guarded(callback)
        return function()
            if runtime.modui_host_keyboard_navigation_ready then return end
            local token = dd.perf.Begin()
            callback()
            dd.perf.End("keybind.navigation", token)
        end
    end
    RegisterKeyBind(Key.UP_ARROW, guarded(runtime.ui_up_key))
    RegisterKeyBind(Key.DOWN_ARROW, guarded(runtime.ui_down_key))
    RegisterKeyBind(Key.LEFT_ARROW, guarded(runtime.ui_left_key))
    RegisterKeyBind(Key.RIGHT_ARROW, guarded(runtime.ui_right_key))
    RegisterKeyBind(Key.RETURN, guarded(runtime.ui_return_key))
    RegisterKeyBind(Key.TAB, guarded(runtime.ui_tab_key))
    RegisterKeyBind(Key.A, guarded(runtime.ui_a_key))
    RegisterKeyBind(Key.D, guarded(runtime.ui_d_key))
    RegisterKeyBind(Key.PAGE_UP, guarded(runtime.ui_page_up_key))
    RegisterKeyBind(Key.PAGE_DOWN, guarded(runtime.ui_page_down_key))
    RegisterKeyBind(Key.ESCAPE, guarded(runtime.ui_escape_key))
    runtime.local_keyboard_navigation_registered = true
    diag("input.keyboardNavigationFallback", {
        status = "registered",
        reason = tostring(reason or "host-unavailable"),
        physicalKeyboardNavigationHost = runtime.modui_host_keyboard_navigation_ready,
    })
    return true
end
runtime.keyboard_navigation_fallback_game = function()
    if not runtime.modui_host_keyboard_navigation_ready then
        runtime.register_local_keyboard_navigation_fallback("bounded-host-ack-unavailable")
    else
        diag("input.keyboardNavigationFallback", {
            status = "not-required",
            physicalKeyboardNavigationHost = true,
        })
    end
end
runtime.keyboard_navigation_fallback_async = function()
    dispatch_game_thread(runtime.keyboard_navigation_fallback_game, "keyboard-navigation-fallback")
end
schedule_one_shot_game_thread(
    6500,
    runtime.keyboard_navigation_fallback_game,
    runtime.keyboard_navigation_fallback_async,
    "keyboard-navigation-fallback")

if input_runtime_ready and type(dd.arm_open_bind_poll) == "function" then
    local arm_ok, arm_result = pcall(dd.arm_open_bind_poll)
    if not arm_ok then
        input_runtime_ready = false
        input_runtime_failure = "poll-arm-exception: " .. tostring(arm_result)
        log("MortalShell2ModUI Runtime.InputHost poll arm failed after construction; lore narration remains active: " .. tostring(arm_result))
        diag("dependency.inputRuntime", { module = "Input.Runtime", stage = "poll-arm", failure = tostring(arm_result), status = "degraded-core-continues" })
    end
end
if input_runtime_ready then
    local keyboard_label = type(dd.keyboard_open_label) == "function" and dd.keyboard_open_label() or tostring(config.menu_keybind)
    local controller_label = type(dd.controller_open_label) == "function" and dd.controller_open_label() or tostring(config.controller_menu_bind)
    log("open bindings keyboard=" .. tostring(keyboard_label) .. " controller=" .. tostring(controller_label) .. " pollArmed=" .. tostring(dd.open_bind_poll_armed))
else
    log("shared input-host runtime unavailable; event-driven lore lifecycle remains armed; reason=" .. tostring(input_runtime_failure))
end

-- Ctrl+Delete writes a [PERF] summary immediately (the same key the minimap uses for
-- its summaries; UE4SS delivers a key bind to every mod that registered it). No-op
-- while performance logging is off.
if type(RegisterKeyBind) == "function" and type(Key) == "table" and Key.DEL ~= nil
    and type(ModifierKey) == "table" and ModifierKey.CONTROL ~= nil then
    local ok_bind = pcall(RegisterKeyBind, Key.DEL, { ModifierKey.CONTROL }, function()
        dd.perf.Emit("ctrl-delete")
    end)
    diag("perf.summaryHotkey", { status = ok_bind and "Ctrl+Delete" or "unavailable",
        logPerformance = dd.config.log_performance == true })
end
log("event-driven reader lifecycle armed; no permanent LoopAsync/EngineTick watcher; configurable chords, short-lived recorder, and read-only conflict inspection use the existing one-shot delayed/input paths when Input.Runtime is ready")
log("ready v" .. VERSION .. "; baseline=v0.9.11-event-driven/v0.9.18-stability; lore-reader=exact-lifecycle-hooks; engines=WindowsSpeech+AzureRESTStreaming; native-reader-shell modal settings=" .. ui.menu_key .. "; input=controller+keyboard+mouse-on-game-owned-IA-menu-map+BPFL-normalized-pointer-with-layout/out-param-fallback+120ms-keyboard/controller/mouse-wheel-cross-source-navigation-dedupe; isolation=exact-owned-GE_BlockGameMenu+interact+movement+camera+abilities-always+optional-balanced-user-pause+balanced-pause-fallback; controller-routing=standalone-WBP_InputListener+exact-1-based-AcceptedInputs+shared-IMC-preserved; admission=BPFL_UI+BPC_UserInterfaceHandler; ui=v0.9.241-native-presentation+native-ui-observer-extraction+v0.9.240-shared-host-presentation-safety+composition-root-extraction+v0.9.239-independent-second-consumer-probe+v0.9.238-shared-menu-semantic-host+v0.9.237-shared-visible-shell-host-cutover+v0.9.236-loading-transition-item32-closure+v0.9.235-save-load-relaunch-evidence+v0.9.234-post-restoration-stress-evidence+v0.9.233-shared-input-restoration-closure+v0.9.232-host-hotkey-capture-isolation+v0.9.231-transition-quarantined-host-open-hotkey+v0.9.230-host-listener-revision-continuity+v0.9.229-host-owned-physical-listener-local-session-hook+v0.9.228-process-wide-native-mirror-rollback+manual-local-budget-headroom+v0.9.227-process-wide-native-mirror-restoration-rejected+v0.9.226-main-local-budget-corrective+v0.9.225-host-analog-authority-corrective+v0.9.224-local-session-native-hook-restoration+v0.9.223-session-scoped-native-ui-observer+delayed-poll-breadcrumbs+v0.9.222-close-quarantine-uobject-exclusion+toggle-wide-release-rearm+v0.9.221-post-transition-quiescence-neutral-edge+v0.9.220-loadmap-pre-post-input-freeze+v0.9.217-request-first-native-mirror-gating+v0.9.216-process-mirror-single-hook-isolation+v0.9.215-post-isolation-failed-open-rollback+v0.9.214-consumer-native-listener-transition-isolation+v0.9.213-gameplay-only-front-end-admission-guard+v0.9.212-transition-settle-admission-guard+v0.9.211-host-open-hotkey-transition-isolation+v0.9.210-local-player-controller-transition-corrective+v0.9.209-shared-menu-shell-observation+v0.9.208-idle-poll-performance-corrective+v0.9.207-shared-menu-lease-native-listener-authority+v0.9.206-shared-menu-session-lease-arbitration+v0.9.205-shared-menu-session-transition-ring-corrective+v0.9.204-shared-menu-session-observation+v0.9.203-shared-menu-provider-control-plane+v0.9.202-standalone-native-listener-primary+v0.9.201-standalone-native-listener-shadow+v0.9.200-host-native-pointer-semantic-delegation+v0.9.199-host-pointer-snapshot-acquisition-corrective+v0.9.198-host-native-pointer-snapshot-observation+v0.9.197-host-native-semantic-runtime-scope-corrective+v0.9.196-host-native-menu-semantic-delegation+v0.9.195-native-input-hook-startup-retry-corrective+v0.9.194-standalone-native-input-hook-mirror+v0.9.193-standalone-keyboard-navigation-host+v0.9.192-on-demand-keyboard-capture-host+v0.9.191-on-demand-controller-digital-capture-host+v0.9.190-standalone-controller-analog-host+v0.9.189-rightY-host-readiness-corrective+v0.9.188-standalone-rightY-host+v0.9.187-host-binding-republish-corrective+v0.9.186-modui-public-api-startup-corrective+v0.9.185-standalone-open-hotkey-host+v0.9.184-modui-host-ack+v0.9.183-modui-host-protocol-registry+v0.9.182-modui-input-host-ownership+v0.9.181-input-runtime-startup-isolation+mai-orthographic-preview-accepted+v0.9.179-runtime-diagnostics+zero-ms-preview-cadence+v0.9.178-runtime-scheduler+ui-pointer+original-preview-cadence-guard+v0.9.177-architecture-accounting+pass99-runtime-proof+v0.9.176-bind-capture-failsafe-corrective+v0.9.175-settings-controller+presentation+preview-cadence+v0.9.174-reader-runtime+voice-browser-controller+v0.9.173-startup-wiring-corrective+v0.9.172-runtime-batch+v0.9.171-engine-status-runtime+v0.9.170-audio-output-runtime+v0.9.169-voice-catalog-runtime+v0.9.168-native-quit-race-freeze+speech-queue-module+v0.9.167-native-confirmation-diagnostic-corrective+v0.9.166-native-ui-transition-observer+v0.9.165-speech-ipc-module+v0.9.164-config-runtime-module+v0.9.163-native-admission-stale-state-hardening+v0.9.162-ui-diagnostics-module+v0.9.161-pronunciation-toggle-freeze+v0.9.160-voice-capability-pronunciation-fallback+v0.9.158-powershell51-utf8nobom-ipa-source-corrective+v0.9.157-azure-ipa-phoneme-pronunciation-corrective+v0.9.156-pronunciation-natural-alias-prosody-corrective+v0.9.155-pronunciation-ps51-list-conversion-corrective+v0.9.154-pronunciation-runtime-corrective+v0.9.153-pronunciation-normalization+v0.9.152-modui-runtime-input-bridge-session-host+v0.9.151-modui-runtime-input-bridge-teardown-plan-host+v0.9.150-modui-runtime-input-bridge-teardown-transaction-host+v0.9.149-modui-runtime-input-bridge-teardown-barrier-host+v0.9.148-modui-runtime-input-bridge-teardown-completion-host+v0.9.147-keyboard-native-directional-dedupe-corrective+v0.9.146-keyboard-native-row-dedupe-corrective+v0.9.145-modui-runtime-input-bridge-teardown-authorization-host+v0.9.144-modui-runtime-input-bridge-teardown-ticket-host+v0.9.143-modui-runtime-input-bridge-lease-teardown-activation-host+v0.9.142-modui-runtime-input-bridge-lease-teardown-options-host+v0.9.141-modui-runtime-input-bridge-lease-router-host+v0.9.140-modui-runtime-input-bridge-lease-hook-spec-host+v0.9.139-modui-runtime-input-bridge-handler-slot-host+v0.9.138-modui-runtime-input-bridge-trampoline-host+v0.9.137-browser-mouse-row-hit-map+v0.9.136-modui-runtime-input-bridge-lease-host+v0.9.135-modui-runtime-input-bridge-construction-host+v0.9.134-modui-runtime-input-bridge-host+tts-input-bridge-diagnostics+v0.9.133-modui-runtime-bridge-lifecycle+v0.9.132-modui-runtime-hook-lifecycle+v0.9.131-modui-runtime-listener-bindings+v0.9.130-modui-runtime-listener-mutation+v0.9.129-modui-runtime-listener-observation+v0.9.128-modui-runtime-resolve+sequence-ipc-transient-gap-hardening+v0.9.127-modui-runtime-observation+admission-snapshot+modular-helper-heartbeat+v0.9.126-modui-runtime-array+admission-policy+v0.9.125-modui-runtime-object+config-storage+v0.9.124-config-codec+modui-input-acceptance+v0.9.123-optional-additive-menu-pause+v0.9.122-contiguous-value-hit-policy+v0.9.121-native-interaction-isolation+v0.9.120-measured-value-control-hit-map+v0.9.119-mouse-hitbox-directional-values+v0.9.118-modui-input-route-dedupe+modular-engine-status+v0.9.116-modui-hold-repeat+modular-duplicate-speech+v0.9.115-modui-stick-capture-gate+modular-audio-output-parser+v0.9.114-modui-input-capture+modular-browser-catalog+v0.9.113-modui-input-conflict+modular-voice-profiles+v0.9.112-modui-input-binding+modular-config-sanitize+v0.9.111-modui-core-value+modular-config-defaults+v0.9.110-modui-settings-details+modular-browser-state+v0.9.109-modui-settings-navigation+modular-ui-layout+v0.9.108-modui-settings-model-render+modular-settings-options+v0.9.107-modui-api1+modular-settings-schema+v0.9.106-transition-safe-shell+modifier-equivalence+persisted-selection-sync+v0.9.105-cached-open-input-owner+v0.9.104-adaptive-helper-polling+v0.9.103-runtime-diagnostic-compaction+v0.9.102-azure-catalog-array-fix+bounded-browser-metadata+v0.9.101-powershell-preflight-runtime-hotfix+v0.9.100-current-version-evidence-scoping+v0.9.98-atomic-heartbeat+recovery-evidence+v0.9.97-release-evidence-gap-closure+v0.9.96-runtime-input+viewport-evidence+v0.9.95-reader-lifecycle+config-provenance-evidence+v0.9.94-runtime-evidence-audit+share-safe-helper-session-summary+v0.9.93-rc-preflight+release-doc-freeze+v0.9.92-capability-safe-voice-profile-memory+shared-browser-commit+support-session-summary+v0.9.91-real-time-recorder-sequence-clock+heartbeat-confirmed-launch-fallback+v0.9.90-canonical-powershell-with-path-fallback+active-helper-loop-release-check+v0.9.89-helper-heartbeat-self-recovery+canonical-powershell-launch+v0.9.88-bounded-recent-duplicate-fingerprints+shared-helper-azure-log-lock+config-recovery-sandbox+v0.9.87-tls12-compat+catalog-transient-retry+identity-redaction+v0.9.86-output-failover+stale-ipc-cleanup+production-helper-sandbox+self-audited-support-zip+v0.9.85-release-integrity+compatibility-matrix+v0.9.84-azure-transient-retry+atomic-dpapi-secret+session-health-summary+v0.9.83-bounded-live-ipc+azure-child-owner-watch+v0.9.82-bounded-runtime-catalogs+real-time-duplicate-clock+v0.9.81-config-staged-and-published-readback+v0.9.80-config-final-marker-validation+v0.9.79-config-schema3+config-last-good-backup+sanitized-persistent-state+v0.9.78-per-voice-tuning+speech-queue+duplicate-suppression+v0.9.77-browser-final-padding+profiled-smoke+safer-voice-gap+compact-close-help+v0.9.76-browser-padding+expanded-smoke+safer-column-ellipsis+compact-browser-help+v0.9.75-predictable-wheel-row+ctrl-shift-wheel-page+right-stick-page-hold-repeat+page-key-hold-repeat+home-end-jump+v0.9.72-dual-window-profiles+browser-page-indicator+browser-hold-repeat+capital-search+browser-page-controls+wheel-row-nav+voice-browser+pitch+azure-style+v0.9.70-inverted-scroll+v0.9.69-neutral-gate+v0.9.59-core-layout+cached-text; close=225ms-generation-guarded+process-retained-passive-shell-no-expiry; dispatch=ProcessEvent-preferred; helper-backend=queue-aware+share-safe-log+compat-preflight+pitch-style-aware")
diag("startup.ready", {
    version = VERSION,
    menuKey = ui.menu_key,
    backend = "frozen-v0.9.18-lineage",
    visual = "v0.9.49-distributed-column-transparent-rails",
    admission = "native-ui-handler",
    acceptedInputs = "one-based-exact-verify",
    isolation = "exact-owned-gameplay-effect-handles",
    pointer = "IA_Menu_Mouse_Left+Right+Wheel+BPFL_UI-normalized+layout/out-param-fallback+three-column-aligned-1080-reference-hit-map",
    offscreenWidgetProbes = "removed",
    redraw = "cached-skip-unchanged",
    shellReuseMs = SHELL_REUSE_MS,
    inputDedupeMs = math.floor(INPUT_CROSS_SOURCE_DEDUPE_SECONDS * 1000.0),
    inputRuntimeReady = input_runtime_ready,
    loadMapTransitionHooks = runtime.load_map_hooks_registered == true,
    loadMapTransitionFreeze = dd.InputRuntime ~= nil and dd.InputRuntime.loadMapTransitionFreeze == true,
    modUiHostRegistrationReady = modui_host_client ~= nil and modui_host_client.RegistrationReady() or false,
    modUiHostAcknowledged = modui_host_client ~= nil and modui_host_client.Acknowledged() or false,
    modUiHostVisibleShellReady = runtime.modui_host_visible_shell_ready,
    modUiHostVisibleShellActive = runtime.modui_host_visible_shell_active,
    modUiHostPresentationSequence = runtime.modui_host_presentation_sequence,
    modUiHostPhysicalHotkeyReady = modui_host_client ~= nil and modui_host_client.HotkeyReady() or false,
    modUiHostKeyboardNavigationReady = runtime.modui_host_keyboard_navigation_ready,
    modUiHostNativeInputHookReady = runtime.modui_host_native_input_hook_ready,
    modUiHostNativeListenerShadowReady = runtime.modui_host_native_listener_shadow_ready,
    modUiHostNativeListenerPrimaryReady = runtime.modui_host_native_listener_primary_ready,
    modUiHostMenuControlReady = runtime.modui_host_menu_control_ready,
    modUiHostMenuSessionObservationReady = runtime.modui_host_menu_session_observation_ready,
    modUiHostMenuSessionTransitionRingReady = runtime.modui_host_menu_session_transition_ring_ready,
    modUiHostMenuLeaseReady = runtime.modui_host_menu_lease_ready,
    modUiHostMenuLeaseAuthorityReady = runtime.modui_host_menu_lease_authority_ready,
    modUiHostMenuShellObservationReady = runtime.modui_host_menu_shell_observation_ready,
    modUiHostBindingRepublish = type(dd.republish_modui_host_binding) == "function",
})
