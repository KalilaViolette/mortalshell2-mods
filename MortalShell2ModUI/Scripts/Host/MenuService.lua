-- MortalShell2ModUI Host.MenuService
-- Primitive-only shared-menu control plane.
-- Pass 160 promotes the control plane into the selector/arbitrator for one standalone
-- ModUI-owned visible Settings shell. Consumers remain executable-semantic owners, but
-- they register primitive descriptors/presentations and request activation through Host.Registry.
-- MenuService deterministically selects one active consumer, one canonical menu-hotkey owner,
-- and one revision/generation-bound lease; Host.ShellService owns the physical UMG lifetime.

local M = {}

local function is_settings_provider(entry)
    return type(entry) == "table"
        and type(entry.fields) == "table"
        and tostring(entry.fields.settings or "") == "1"
        and tostring(entry.consumer or "") ~= ""
        and tonumber(entry.slot) ~= nil
end

local function provider_sort(a, b)
    local ao = type(a.fields) == "table" and math.floor(tonumber(a.fields.menuOrder) or 100) or 100
    local bo = type(b.fields) == "table" and math.floor(tonumber(b.fields.menuOrder) or 100) or 100
    if ao ~= bo then return ao < bo end
    local as = math.floor(tonumber(a.slot) or 2147483647)
    local bs = math.floor(tonumber(b.slot) or 2147483647)
    if as ~= bs then return as < bs end
    return tostring(a.consumer or "") < tostring(b.consumer or "")
end

local function session_metadata(selected, session, host_epoch)
    local metadata = {
        state = "idle", consumer = "", slot = -1, revision = 0,
        sequence = 0, generation = 0, reason = "", hostEpoch = tostring(host_epoch or ""),
    }
    if selected ~= nil then
        metadata.consumer = tostring(selected.consumer or "")
        metadata.slot = math.floor(tonumber(selected.slot) or -1)
        metadata.revision = math.max(0, math.floor(tonumber(selected.revision) or 0))
    end
    if type(session) == "table" then
        metadata.state = tostring(session.state or "idle")
        metadata.sequence = math.max(0, math.floor(tonumber(session.sequence) or 0))
        metadata.generation = math.max(0, math.floor(tonumber(session.generation) or 0))
        metadata.reason = tostring(session.reason or "")
    end
    return metadata
end

local function session_signature(metadata)
    return table.concat({
        tostring(metadata.state or ""), tostring(metadata.consumer or ""), tostring(metadata.slot or -1),
        tostring(metadata.revision or 0), tostring(metadata.sequence or 0), tostring(metadata.generation or 0),
        tostring(metadata.reason or ""), tostring(metadata.hostEpoch or ""),
    }, "|")
end

function M.Bind(registry, protocol)
    if type(registry) ~= "table" then return nil, "Host.MenuService requires Host.Registry instance" end
    if type(protocol) ~= "table" then return nil, "Host.MenuService requires Host.Protocol" end
    if type(registry.PublishMenuState) ~= "function"
        or type(registry.ReadConsumerMenuSessionEvents) ~= "function"
        or type(registry.PublishMenuSessionState) ~= "function"
        or type(registry.ReadConsumerMenuLease) ~= "function"
        or type(registry.PublishMenuLeaseState) ~= "function"
        or type(registry.ReadConsumerMenuShell) ~= "function"
        or type(registry.PublishMenuShellState) ~= "function" then
        return nil, "Host.MenuService registry menu-state API incomplete"
    end

    local self = {
        last_signature = "",
        last_session_signature = "",
        last_session_sequence = 0,
        last_lease_signature = "",
        last_shell_signature = "",
        selected_signature = "",
        reconciliation_count = 0,
        selected = nil,
    }

    function self.Reconcile(registrations, host_epoch)
        local providers = {}
        for _, entry in ipairs(registrations or {}) do
            if is_settings_provider(entry) then providers[#providers + 1] = entry end
        end
        table.sort(providers, provider_sort)

        local requested_consumer = ""
        if type(registry.ReadMenuActiveConsumerRequest) == "function" then
            local requested = registry.ReadMenuActiveConsumerRequest()
            requested_consumer = tostring(requested or "")
        end
        local selected = nil
        if requested_consumer ~= "" then
            for _, provider in ipairs(providers) do
                if tostring(provider.consumer or "") == requested_consumer then selected = provider; break end
            end
        end
        if selected == nil and self.selected ~= nil then
            local prior = tostring(self.selected.consumer or "")
            for _, provider in ipairs(providers) do
                if tostring(provider.consumer or "") == prior then selected = provider; break end
            end
        end
        if selected == nil then selected = providers[1] end
        self.selected = selected
        self.providers = providers
        self.hotkey_owner = nil
        for _, provider in ipairs(providers) do
            if type(provider.fields) == "table" and tostring(provider.fields.hotkeys or "0") == "1" then
                self.hotkey_owner = provider
                break
            end
        end
        local provider_identity = selected ~= nil and table.concat({
            tostring(selected.consumer or ""), tostring(math.floor(tonumber(selected.slot) or -1)),
            tostring(math.max(0, math.floor(tonumber(selected.revision) or 0))),
        }, "|") or ""
        if provider_identity ~= self.selected_signature then
            -- A new descriptor revision must not inherit the old revision's ring cursor or
            -- canonical session state. The next Tick either accepts a fresh-revision event
            -- or publishes canonical idle until one arrives.
            self.selected_signature = provider_identity
            self.last_session_sequence = 0
            self.last_session_signature = ""
            self.last_lease_signature = ""
            self.last_shell_signature = ""
        end

        local metadata = {
            state = selected ~= nil and "ready" or "idle",
            providerCount = #providers,
            providerConsumer = selected ~= nil and tostring(selected.consumer or "") or "",
            providerSlot = selected ~= nil and math.floor(tonumber(selected.slot) or -1) or -1,
            providerRevision = selected ~= nil and math.max(0, math.floor(tonumber(selected.revision) or 0)) or 0,
            providerDisplay = selected ~= nil and tostring(selected.fields.display or selected.consumer or "") or "",
            providerPages = selected ~= nil and tostring(selected.fields.pages or "") or "",
            providerActions = selected ~= nil and tostring(selected.fields.actions or "") or "",
            hotkeyOwnerConsumer = self.hotkey_owner ~= nil and tostring(self.hotkey_owner.consumer or "") or "",
            hotkeyOwnerSlot = self.hotkey_owner ~= nil and math.floor(tonumber(self.hotkey_owner.slot) or -1) or -1,
            hotkeyOwnerRevision = self.hotkey_owner ~= nil and math.max(0, math.floor(tonumber(self.hotkey_owner.revision) or 0)) or 0,
            providerVisibleShell = selected ~= nil and tostring(selected.fields.visibleShell or "0") == "1" or false,
            providerPresentation = selected ~= nil and tostring(selected.fields.presentation or "0") == "1" or false,
            activeConsumer = selected ~= nil and tostring(selected.consumer or "") or "",
            providerConsumers = table.concat((function()
                local out = {}; for _, provider in ipairs(providers) do out[#out + 1] = tostring(provider.consumer or "") end; return out
            end)(), ","),
            hostEpoch = tostring(host_epoch or ""),
        }

        local signature = table.concat({
            metadata.state, tostring(metadata.providerCount), metadata.providerConsumer,
            tostring(metadata.providerSlot), tostring(metadata.providerRevision), metadata.providerDisplay,
            metadata.providerPages, metadata.providerActions, metadata.hotkeyOwnerConsumer,
            tostring(metadata.hotkeyOwnerSlot), tostring(metadata.hotkeyOwnerRevision), tostring(metadata.providerVisibleShell),
            tostring(metadata.providerPresentation), metadata.activeConsumer, metadata.providerConsumers, metadata.hostEpoch,
        }, "|")
        metadata.changed = signature ~= self.last_signature

        local ok, publish_err = registry.PublishMenuState(metadata)
        if not ok then return nil, publish_err end

        self.last_signature = signature
        self.reconciliation_count = self.reconciliation_count + 1
        metadata.reconciliationCount = self.reconciliation_count
        return metadata
    end

    function self.Tick(host_epoch)
        local requested = type(registry.ReadMenuActiveConsumerRequest) == "function"
            and registry.ReadMenuActiveConsumerRequest() or ""
        if type(requested) == "string" and requested ~= ""
            and (self.selected == nil or tostring(self.selected.consumer or "") ~= requested) then
            -- A second consumer may observe its hotkey during another provider's
            -- active modal session. Never let that request steal the canonical
            -- provider/lease: the losing consumer's failed-open cleanup must not
            -- hide the current shell or strand its pause and input blockers.
            local current_session = type(registry.ReadMenuSessionState) == "function"
                and registry.ReadMenuSessionState() or nil
            local current_lease = type(registry.ReadMenuLeaseState) == "function"
                and registry.ReadMenuLeaseState() or nil
            local session_state = tostring(type(current_session) == "table" and current_session.state or "idle")
            local session_active = session_state == "opening" or session_state == "ready" or session_state == "closing"
            local lease_granted = type(current_lease) == "table"
                and tostring(current_lease.state or "") == "granted"
            if self.selected ~= nil and (session_active or lease_granted) then
                if type(registry.SetMenuActiveConsumerRequest) == "function" then
                    registry.SetMenuActiveConsumerRequest(tostring(self.selected.consumer or ""))
                end
            else
                self.Reconcile(self.providers or {}, host_epoch)
            end
        end
        local selected = self.selected
        local events = {}
        local head = self.last_session_sequence
        if selected ~= nil then
            local consumer = tostring(selected.consumer or "")
            local slot = math.floor(tonumber(selected.slot) or -1)
            local revision = math.max(0, math.floor(tonumber(selected.revision) or 0))
            local drained, read_head = registry.ReadConsumerMenuSessionEvents(
                slot, consumer, revision, self.last_session_sequence)
            if drained == nil then return nil, read_head end
            events = drained
            head = math.max(self.last_session_sequence, math.floor(tonumber(read_head) or 0))
        end

        local published_events = {}
        for _, session in ipairs(events) do
            local metadata = session_metadata(selected, session, host_epoch)
            local signature = session_signature(metadata)
            metadata.changed = signature ~= self.last_session_signature
            if metadata.changed then
                local ok, publish_err = registry.PublishMenuSessionState(metadata)
                if not ok then return nil, publish_err end
                self.last_session_signature = signature
                published_events[#published_events + 1] = metadata
            end
        end
        self.last_session_sequence = head

        -- Provider removal/revision change must immediately invalidate any canonical state
        -- from the previous provider. If no fresh event is available yet, publish idle.
        if #published_events == 0 and self.last_session_signature == "" then
            local idle = session_metadata(selected, nil, host_epoch)
            local signature = session_signature(idle)
            local ok, publish_err = registry.PublishMenuSessionState(idle)
            if not ok then return nil, publish_err end
            self.last_session_signature = signature
            idle.changed = true
            published_events[#published_events + 1] = idle
        end

        local final = published_events[#published_events]
        if final == nil then
            local current = type(registry.ReadMenuSessionState) == "function" and registry.ReadMenuSessionState() or nil
            final = type(current) == "table" and current or session_metadata(selected, nil, host_epoch)
            final.changed = false
        end
        local lease = {
            state = "idle", consumer = "", slot = -1, revision = 0,
            sequence = 0, generation = 0, reason = "", hostEpoch = tostring(host_epoch or ""),
            changed = false,
        }
        if selected ~= nil then
            local consumer = tostring(selected.consumer or "")
            local slot = math.floor(tonumber(selected.slot) or -1)
            local revision = math.max(0, math.floor(tonumber(selected.revision) or 0))
            local intent = registry.ReadConsumerMenuLease(slot, consumer, revision)
            local session_active = tostring(final.state or "") == "opening"
                or tostring(final.state or "") == "ready"
                or tostring(final.state or "") == "closing"
            if type(intent) == "table" and intent.active == true
                and session_active
                and math.max(0, math.floor(tonumber(intent.generation) or 0)) == math.max(0, math.floor(tonumber(final.generation) or 0)) then
                lease.state = "granted"
                lease.consumer = consumer
                lease.slot = slot
                lease.revision = revision
                lease.sequence = math.max(0, math.floor(tonumber(intent.sequence) or 0))
                lease.generation = math.max(0, math.floor(tonumber(intent.generation) or 0))
                lease.reason = tostring(intent.reason or "")
            elseif type(intent) == "table" then
                lease.sequence = math.max(0, math.floor(tonumber(intent.sequence) or 0))
                lease.generation = math.max(0, math.floor(tonumber(intent.generation) or 0))
                lease.reason = tostring(intent.reason or "")
            end
        end
        local lease_signature = table.concat({
            lease.state, lease.consumer, tostring(lease.slot), tostring(lease.revision),
            tostring(lease.sequence), tostring(lease.generation), lease.reason, lease.hostEpoch,
        }, "|")
        lease.changed = lease_signature ~= self.last_lease_signature
        if lease.changed then
            local ok, publish_err = registry.PublishMenuLeaseState(lease)
            if not ok then return nil, publish_err end
            self.last_lease_signature = lease_signature
        end


        local shell = {
            state = "none", consumer = "", slot = -1, revision = 0,
            sequence = 0, generation = 0, address = "", reused = false,
            cacheToken = 0, reason = "", hostEpoch = tostring(host_epoch or ""),
            changed = false,
        }
        if selected ~= nil then
            local consumer = tostring(selected.consumer or "")
            local slot = math.floor(tonumber(selected.slot) or -1)
            local revision = math.max(0, math.floor(tonumber(selected.revision) or 0))
            local observed = registry.ReadConsumerMenuShell(slot, consumer, revision)
            if type(observed) == "table" then
                local observed_generation = math.max(0, math.floor(tonumber(observed.generation) or 0))
                local final_generation = math.max(0, math.floor(tonumber(final.generation) or 0))
                local state = tostring(observed.state or "none")
                local generation_matches = state == "none"
                    or observed_generation == final_generation
                    or (state == "retained" and tostring(final.state or "") == "closed")
                    or (state == "retired" and tostring(final.state or "") == "closed")
                if generation_matches then
                    shell.state = state
                    shell.consumer = consumer
                    shell.slot = slot
                    shell.revision = revision
                    shell.sequence = math.max(0, math.floor(tonumber(observed.sequence) or 0))
                    shell.generation = observed_generation
                    shell.address = tostring(observed.address or "")
                    shell.reused = observed.reused == true
                    shell.cacheToken = math.max(0, math.floor(tonumber(observed.cacheToken) or 0))
                    shell.reason = tostring(observed.reason or "")
                end
            end
        end
        local shell_signature = table.concat({
            shell.state, shell.consumer, tostring(shell.slot), tostring(shell.revision),
            tostring(shell.sequence), tostring(shell.generation), shell.address,
            tostring(shell.reused), tostring(shell.cacheToken), shell.reason, shell.hostEpoch,
        }, "|")
        shell.changed = shell_signature ~= self.last_shell_signature
        if shell.changed then
            local ok, publish_err = registry.PublishMenuShellState(shell)
            if not ok then return nil, publish_err end
            self.last_shell_signature = shell_signature
        end

        final.events = published_events
        final.drainedCount = #events
        final.headSequence = head
        final.lease = lease
        final.shell = shell
        return final
    end

    function self.Selected()
        return self.selected
    end

    function self.Providers()
        local out = {}
        for index, provider in ipairs(self.providers or {}) do out[index] = provider end
        return out
    end

    function self.HotkeyOwner()
        return self.hotkey_owner
    end

    return self
end

return M
