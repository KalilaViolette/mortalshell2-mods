-- MortalShell2ModUI Input.Acceptance
-- Pure numeric accepted-input list/set transforms. Runtime.Listener now owns bounded
-- AcceptedInputs mutation/verification/restoration; consumers still own diagnostics,
-- listener lifetime, hooks/dispatch, and restoration timing.

local Acceptance = {}

function Acceptance.ListCsv(values)
    if type(values) ~= "table" then return "<nil>" end
    local parts = {}
    for index, value in ipairs(values) do
        parts[index] = tostring(value)
    end
    return table.concat(parts, ",")
end

function Acceptance.SetDiff(expected, actual)
    local expected_set, actual_set = {}, {}
    for _, value in ipairs(expected or {}) do expected_set[tonumber(value)] = true end
    for _, value in ipairs(actual or {}) do actual_set[tonumber(value)] = true end

    local missing, unexpected = {}, {}
    for value in pairs(expected_set) do
        if not actual_set[value] then missing[#missing + 1] = value end
    end
    for value in pairs(actual_set) do
        if not expected_set[value] then unexpected[#unexpected + 1] = value end
    end
    table.sort(missing)
    table.sort(unexpected)
    return missing, unexpected
end

function Acceptance.Contains(values, needle)
    needle = tonumber(needle)
    if needle == nil or type(values) ~= "table" then return false end
    for _, value in ipairs(values) do
        if tonumber(value) == needle then return true end
    end
    return false
end

function Acceptance.Exact(expected, actual)
    local missing, unexpected = Acceptance.SetDiff(expected, actual)
    local expected_count = type(expected) == "table" and #expected or 0
    local actual_count = type(actual) == "table" and #actual or 0
    return expected_count == actual_count and #missing == 0 and #unexpected == 0, missing, unexpected
end

return Acceptance
