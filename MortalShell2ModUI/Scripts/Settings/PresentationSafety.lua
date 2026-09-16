-- MortalShell2ModUI Settings.PresentationSafety
-- Pure defensive bounds for primitive consumer-provided shared-shell presentation.
-- Consumers remain responsible for polished formatting; the host guarantees that an
-- oversized or malformed string cannot spill indefinitely into neighboring native rails.

local M = {}

function M.Bind(Text, Layout)
    if type(Text) ~= "table" or type(Text.EllipsizeLines) ~= "function" then
        return nil, "Settings.PresentationSafety requires Text.EllipsizeLines"
    end
    if type(Layout) ~= "table" or type(Layout.presentation) ~= "table" then
        return nil, "Settings.PresentationSafety requires Layout.presentation"
    end

    local function sanitize(snapshot)
        if type(snapshot) ~= "table" then return snapshot, false, {} end
        local profile = tostring(snapshot.profile or "main") == "browser" and "browser" or "main"
        local limits = type(Layout.presentation[profile]) == "table" and Layout.presentation[profile] or {}
        local copy = {}
        for key, value in pairs(snapshot) do copy[key] = value end
        local changed_fields = {}

        local function clip(field, max_chars, max_lines)
            local original = tostring(copy[field] or "")
            local clipped, changed = Text.EllipsizeLines(original, max_chars, max_lines)
            copy[field] = clipped
            if changed then changed_fields[#changed_fields + 1] = field end
        end

        clip("header", limits.header or 72, 1)
        clip("page", limits.page or 16, 1)
        clip("tabs", limits.tabs or 96, 2)
        clip("tabLabels", 48, 16)
        clip("rowKinds", 16, 32)
        clip("rowProgress", 16, 32)
        clip("labels", limits.labelLine or 42, 0)
        clip("values", limits.valueLine or 44, 0)
        clip("body", limits.bodyLine or 120, 0)
        clip("detailTitle", limits.detailTitle or 64, 2)
        clip("details", limits.detailLine or 104, limits.detailLines or 24)

        return copy, #changed_fields > 0, changed_fields
    end

    return {
        Sanitize = sanitize,
    }
end

return M
