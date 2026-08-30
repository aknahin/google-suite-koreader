--[[--
Date and time formatting for compact e-ink lists.
--]]

local _ = require("gettext")

local Fmt = {}

--- "14:05" for today, "3 Sep" this year, "3 Sep 25" otherwise.
function Fmt.shortDate(epoch)
    if not epoch or epoch == 0 then return "" end
    local now = os.time()
    if os.date("%Y-%m-%d", epoch) == os.date("%Y-%m-%d", now) then
        return os.date("%H:%M", epoch)
    elseif os.date("%Y", epoch) == os.date("%Y", now) then
        return os.date("%-d %b", epoch)
    end
    return os.date("%-d %b %y", epoch)
end

function Fmt.dateTime(epoch)
    if not epoch then return "" end
    return os.date("%a %-d %b %Y, %H:%M", epoch)
end

function Fmt.clock(epoch)
    if not epoch then return "" end
    return os.date("%H:%M", epoch)
end

--- "5:20 PM". Built from os.date("*t") rather than a strftime pattern: %-I and
--- %p are not portable across the libcs KOReader ships on, and %p is empty in
--- some locales, which would silently drop the meridiem.
function Fmt.clock12(epoch)
    if not epoch then return "" end
    local parts = os.date("*t", epoch)
    local hour = parts.hour % 12
    if hour == 0 then hour = 12 end
    return string.format("%d:%02d %s", hour, parts.min, parts.hour < 12 and "AM" or "PM")
end

--- "Today", "Tomorrow", or "Wed 3 Sep" for a YYYY-MM-DD key.
function Fmt.dayHeading(day_key)
    local now = os.time()
    if day_key == os.date("%Y-%m-%d", now) then return _("Today") end
    if day_key == os.date("%Y-%m-%d", now + 86400) then return _("Tomorrow") end
    if day_key == os.date("%Y-%m-%d", now - 86400) then return _("Yesterday") end

    local year, month, day = day_key:match("^(%d+)%-(%d+)%-(%d+)$")
    if not year then return day_key end
    -- Noon avoids any DST edge when turning the date back into a timestamp.
    local epoch = os.time{ year = tonumber(year), month = tonumber(month),
                           day = tonumber(day), hour = 12 }
    if os.date("%Y", epoch) == os.date("%Y", now) then
        return os.date("%a %-d %b", epoch)
    end
    return os.date("%a %-d %b %Y", epoch)
end

--- Titles for the grid views. Built from a noon-UTC timestamp and formatted with
--- os.date's UTC flag, so the label can never slip a day in either direction.
function Fmt.monthTitle(year, month)
    local Gcal = require("lib/gcal")
    return os.date("!%B %Y", Gcal.timegm(year, month, 1, 12, 0, 0))
end

function Fmt.weekTitle(first_key, last_key)
    local Gcal = require("lib/gcal")
    local function stamp(key)
        local y, m, d = key:match("^(%d+)%-(%d+)%-(%d+)$")
        return Gcal.timegm(tonumber(y), tonumber(m), tonumber(d), 12, 0, 0)
    end
    local first, last = stamp(first_key), stamp(last_key)
    local first_label = os.date("!%Y", first) == os.date("!%Y", last)
        and os.date("!%-d %b", first) or os.date("!%-d %b %Y", first)
    return first_label .. " – " .. os.date("!%-d %b %Y", last)
end

--- Clips a single-line string so long subjects do not push the date off-screen.
function Fmt.clip(text, max_chars)
    text = (text or ""):gsub("%s+", " "):gsub("^%s", ""):gsub("%s$", "")
    if #text <= max_chars then return text end
    return text:sub(1, max_chars - 1) .. "…"
end

return Fmt
