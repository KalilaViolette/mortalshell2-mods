-- MortalShell2ModUI Host.Service
-- Standalone-host consumer discovery/acknowledgement coordinator.
-- This service owns no Unreal objects, input listener, or gameplay behavior. Pass 108
-- allows the standalone Host.InputService physical-hotkey poll to reuse its revision-aware
-- scan/ack path when registrations change; native menu ownership remains out of scope.

local M = {}

function M.Bind(registry, protocol)
    if type(registry) ~= "table" then return nil, "Host.Service requires Host.Registry instance" end
    if type(protocol) ~= "table" then return nil, "Host.Service requires Host.Protocol" end
    if type(registry.Scan) ~= "function"
        or type(registry.Acknowledge) ~= "function"
        or type(registry.ReadRegistryRevision) ~= "function" then
        return nil, "Host.Service registry API incomplete"
    end

    local self = {
        last_registry_revision = -1,
        total_acknowledgements = 0,
        registered_consumers = {},
        registered_registrations = {},
    }

    function self.ScanAndAcknowledge(host_epoch, force)
        local registry_revision, revision_err = registry.ReadRegistryRevision()
        if registry_revision == nil then
            return nil, "registry revision read failed: " .. tostring(revision_err)
        end

        local force_scan = force == true
        if not force_scan and registry_revision == self.last_registry_revision then
            return {
                changed = false,
                registryRevision = registry_revision,
                entries = 0,
                acknowledged = 0,
                failures = 0,
                consumers = self.registered_consumers,
                registrations = self.registered_registrations,
                totalAcknowledgements = self.total_acknowledgements,
            }
        end

        local entries = registry.Scan()
        local acknowledged = 0
        local failures = 0
        local consumers = {}

        for _, entry in ipairs(entries or {}) do
            if type(entry) == "table" and entry.consumer ~= nil and entry.slot ~= nil then
                local ok = registry.Acknowledge(entry.slot, entry.consumer, host_epoch, entry.revision)
                if ok then
                    acknowledged = acknowledged + 1
                    self.total_acknowledgements = self.total_acknowledgements + 1
                    consumers[#consumers + 1] = tostring(entry.consumer)
                else
                    failures = failures + 1
                end
            end
        end

        self.last_registry_revision = registry_revision
        self.registered_consumers = consumers
        self.registered_registrations = entries or {}

        return {
            changed = true,
            registryRevision = registry_revision,
            entries = #(entries or {}),
            acknowledged = acknowledged,
            failures = failures,
            consumers = consumers,
            registrations = self.registered_registrations,
            totalAcknowledgements = self.total_acknowledgements,
        }
    end

    return self
end

return M
