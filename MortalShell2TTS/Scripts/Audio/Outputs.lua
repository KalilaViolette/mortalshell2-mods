-- MortalShell2TTS Audio.Outputs
-- Pure parser for the helper-published audio-output TSV snapshot. File IO,
-- config selection, helper synchronization and runtime fallback remain in main.lua.

local Outputs = {}

function Outputs.Parse(content, sanitize_text, max_entries)
    sanitize_text = type(sanitize_text) == "function" and sanitize_text or function(value) return tostring(value or "") end
    max_entries = math.max(1, math.floor(tonumber(max_entries) or 1024))

    local values = {
        { value = "default", label = "System Default" },
    }
    local seen = { ["default"] = true }
    local accepted = 0
    local truncated = false

    if content ~= nil then
        for raw_line in tostring(content):gmatch("[^\r\n]+") do
            if accepted >= max_entries then
                truncated = true
                break
            end

            local token_id, label = raw_line:match("^(.-)\t(.*)$")
            if token_id == nil then
                token_id = sanitize_text(raw_line, "", 512)
                label = token_id
            else
                token_id = sanitize_text(token_id, "", 512)
                label = sanitize_text(label, token_id, 512)
            end

            local key = tostring(token_id):lower()
            if token_id ~= "" and not seen[key] then
                seen[key] = true
                values[#values + 1] = { value = token_id, label = label ~= "" and label or token_id }
                accepted = accepted + 1
            end
        end
    end

    return values, { accepted = accepted, truncated = truncated }
end

return Outputs
