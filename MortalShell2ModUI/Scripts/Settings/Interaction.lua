-- Shared pure pointer and navigation policy. Blank/details areas never edit settings.
local M = {}

function M.Action(action)
    return ({ a = "previous_tab", d = "next_tab", ["page-up"] = "previous_tab",
        ["page-down"] = "next_tab", tab = "next_tab", enter = "confirm",
        escape = "back" })[action] or action
end

function M.Pointer(event)
    local x, y = tonumber(event.pointerX), tonumber(event.pointerY)
    local w, h = tonumber(event.viewportWidth), tonumber(event.viewportHeight)
    if not x or not y or not w or not h or w <= 0 or h <= 0 then return nil end
    local scale = h / 1080
    return { x = (x - w * 0.5) / scale + 960, y = y / scale }
end

-- Row indices returned here are tab-absolute. When the tab has more rows than the
-- shell shows (Settings.Viewport), the hit is taken against the visible window and
-- mapped back, using the same pure window the host rendered from.
local function viewport()
    local ok, module = pcall(function() return M.Viewport end)
    return ok and type(module) == "table" and type(module.Window) == "function" and module or nil
end

-- v0.70.0: `options.resolved` and `options.window` are the layout and tab window the
-- host actually drew (Host.ShellService measures its rails and lays the strip out); with
-- them the answer is exact. Without them -- a consumer resolving on its own against an
-- older host -- the pure model stands in. The strip's "<" / ">" scroll marks answer as
-- { kind = "tab-scroll", direction = -1 / 1 }; a tab answers with its absolute index.
function M.Hit(layout, profile, snapshot, tab_labels, selected_tab, row_count, x, y, options)
    if type(x) ~= "number" or type(y) ~= "number" or x ~= x or y ~= y then return nil end
    options = type(options) == "table" and options or {}
    local resolved = type(options.resolved) == "table" and options.resolved
        or layout.ResolveAdaptive(profile, snapshot.labels, snapshot.values, options.calibration)
    local hit, c = resolved.pointer, layout.settings
    if profile ~= "browser" then
        local strip = layout.ResolveTabHitRegions(tab_labels, selected_tab, resolved, options.window)
        if y >= strip.top and y < strip.bottom then
            if strip.prevRegion ~= nil and x >= strip.prevRegion.left and x < strip.prevRegion.right then
                return { kind = "tab-scroll", direction = -1 }
            end
            if strip.nextRegion ~= nil and x >= strip.nextRegion.left and x < strip.nextRegion.right then
                return { kind = "tab-scroll", direction = 1 }
            end
            for _, r in ipairs(strip.regions) do
                if x >= r.left and x < r.right then return { kind = "tab", index = r.index } end
            end
        end
    end
    local top = profile == "browser" and c.BROWSER_ROW_HIT_TOP or c.MAIN_ROW_HIT_TOP
    local step = c.ROW_HIT_STEP
    local first, visible_count = 1, row_count
    local Viewport = profile ~= "browser" and viewport() or nil
    if Viewport ~= nil then
        local last
        first, last = Viewport.Window(row_count, snapshot.selectedRow)
        visible_count = last - first + 1
    end
    if x < hit.rowLeft or x >= hit.rowRight or y < top or y >= top + visible_count * step then return nil end
    local index = math.floor((y - top) / step) + first
    if x >= hit.valueLeft and x < hit.valueRight then
        return { kind = "value", index = index, direction = x < (hit.previousRight or hit.valueLeft) and -1 or 1 }
    end
    return { kind = "label", index = index }
end

-- Two confirmations on the same row, page and session; selection/page changes cancel.
function M.ResetConfirmation(state, key, generation)
    local signature = tostring(generation) .. ":" .. tostring(key)
    if state.pending_reset == signature then state.pending_reset = nil; return true end
    state.pending_reset = signature
    return false
end

return M
