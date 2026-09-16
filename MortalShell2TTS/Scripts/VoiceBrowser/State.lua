-- MortalShell2TTS Voice Browser state factory.
-- TTS-specific state only; no hooks, Unreal objects, timers, or UI ownership.

local State = {}

function State.New()
    return {
        active = false,
        query = "",
        gender = "All",
        genders = { "All", "Female", "Male" },
        chosen = "",
        original = "",
        filtered = {},
        offset = 1,
        page_size = 10,
        previous_search_down = {},
        nav_hold_ticks = { up = 0, down = 0 },
        square_down = false,
        -- Page-sized controls use keyboard-style hold repeat. The first page is immediate,
        -- then a short initial pause prevents accidental runaway navigation before a
        -- controlled repeat cadence begins. Right-stick page repeat is intentionally
        -- slower than row repeat because each page move redraws the larger browser view.
        right_page_hold_direction = 0,
        right_page_hold_ticks = 0,
        right_page_neutral_seen = true,
        right_page_springback_logged = false,
        page_hold_ticks = { up = 0, down = 0 },
        home_down = false,
        end_down = false,
    }
end

return State
