--[[--
Google Calendar: a read-only agenda across the user's selected calendars.

Times arrive as RFC 3339 with an explicit offset, so they are converted to epoch
seconds here rather than through `os.time`, which interprets its argument in the
device's local zone. All-day events carry a bare date and no zone at all; those
stay as date strings and are never pushed through a timezone conversion.
--]]

local logger = require("logger")
local socket_url = require("socket.url")
local _ = require("gettext")

local Account = require("lib/account")
local Batch = require("lib/batch")
local Const = require("lib/const")
local Http = require("lib/http")

local Gcal = {}

local BATCH_URL = "https://www.googleapis.com/batch/calendar/v3"

--- Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's algorithm).
local function daysFromCivil(year, month, day)
    year = month <= 2 and year - 1 or year
    local era = math.floor(year / 400)
    local year_of_era = year - era * 400
    local day_of_year = math.floor((153 * (month + (month > 2 and -3 or 9)) + 2) / 5) + day - 1
    local day_of_era = year_of_era * 365 + math.floor(year_of_era / 4)
        - math.floor(year_of_era / 100) + day_of_year
    return era * 146097 + day_of_era - 719468
end

--- Epoch seconds for a UTC calendar date/time, independent of the device zone.
function Gcal.timegm(year, month, day, hour, minute, second)
    return daysFromCivil(year, month, day) * 86400 + hour * 3600 + minute * 60 + second
end

--- Inverse of daysFromCivil (Hinnant's civil_from_days).
local function civilFromDays(days)
    local z = days + 719468
    local era = math.floor(z / 146097)
    local day_of_era = z - era * 146097
    local year_of_era = math.floor((day_of_era - math.floor(day_of_era / 1460)
        + math.floor(day_of_era / 36524) - math.floor(day_of_era / 146096)) / 365)
    local year = year_of_era + era * 400
    local day_of_year = day_of_era - (365 * year_of_era + math.floor(year_of_era / 4)
        - math.floor(year_of_era / 100))
    local month_prime = math.floor((5 * day_of_year + 2) / 153)
    local day = day_of_year - math.floor((153 * month_prime + 2) / 5) + 1
    local month = month_prime + (month_prime < 10 and 3 or -9)
    return year + (month <= 2 and 1 or 0), month, day
end

--- Grid layout is pure date arithmetic; keeping it off os.time/os.date means it
--- cannot drift with the device timezone or a DST boundary.
function Gcal.dayKeyToDays(day_key)
    local year, month, day = day_key:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if not year then return nil end
    return daysFromCivil(tonumber(year), tonumber(month), tonumber(day))
end

function Gcal.daysToDayKey(days)
    return string.format("%04d-%02d-%02d", civilFromDays(days))
end

--- Day of week for a day key: 1 = Sunday .. 7 = Saturday (Lua's os.date wday).
--- 1970-01-01 was a Thursday, hence the +4.
function Gcal.weekdayOf(day_key)
    local days = Gcal.dayKeyToDays(day_key)
    if not days then return nil end
    return (days + 4) % 7 + 1
end

local DAYS_IN_MONTH = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

function Gcal.daysInMonth(year, month)
    if month == 2 and (year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)) then
        return 29
    end
    return DAYS_IN_MONTH[month]
end

--[[--
The day cells of a month grid, including the leading and trailing days borrowed
from the neighbouring months so every row is full.

@tparam number start_dow 1 = Sunday .. 7 = Saturday (2 = Monday is the default)
@treturn table list of { key, day, outside }, length 28/35/42
--]]
function Gcal.monthDays(year, month, start_dow)
    start_dow = start_dow or 2
    local first_key = string.format("%04d-%02d-01", year, month)
    local first_days = Gcal.dayKeyToDays(first_key)
    -- How far back the grid starts from the 1st.
    local lead = (Gcal.weekdayOf(first_key) - start_dow) % 7
    local total = lead + Gcal.daysInMonth(year, month)
    local rows = math.ceil(total / 7)

    local cells = {}
    for offset = 0, rows * 7 - 1 do
        local days = first_days - lead + offset
        local cell_year, cell_month, cell_day = civilFromDays(days)
        cells[#cells + 1] = {
            key     = Gcal.daysToDayKey(days),
            day     = cell_day,
            outside = not (cell_year == year and cell_month == month),
        }
    end
    return cells
end

--- The seven day cells of the week containing `day_key`.
function Gcal.weekDays(day_key, start_dow)
    start_dow = start_dow or 2
    local days = Gcal.dayKeyToDays(day_key)
    if not days then return {} end
    local lead = (Gcal.weekdayOf(day_key) - start_dow) % 7
    local cells = {}
    for offset = 0, 6 do
        local cell_days = days - lead + offset
        local _y, _m, cell_day = civilFromDays(cell_days)
        cells[#cells + 1] = { key = Gcal.daysToDayKey(cell_days), day = cell_day }
    end
    return cells
end

--- Groups normalized events by day key, all-day first, then by start time.
function Gcal.bucketByDay(events)
    local buckets = {}
    for _i, event in ipairs(events or {}) do
        local bucket = buckets[event.day_key]
        if not bucket then
            bucket = {}
            buckets[event.day_key] = bucket
        end
        bucket[#bucket + 1] = event
    end
    for _key, bucket in pairs(buckets) do
        table.sort(bucket, function(a, b)
            if a.all_day ~= b.all_day then return a.all_day end
            return (a.start_epoch or 0) < (b.start_epoch or 0)
        end)
    end
    return buckets
end

--- Parses "2026-08-30T14:05:00+06:00" / "...Z" into epoch seconds.
function Gcal.parseRfc3339(text)
    if type(text) ~= "string" then return nil end
    local year, month, day, hour, minute, second, rest =
        text:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)%.?%d*(.*)$")
    if not year then return nil end
    local epoch = Gcal.timegm(tonumber(year), tonumber(month), tonumber(day),
                              tonumber(hour), tonumber(minute), tonumber(second))
    local sign, offset_hour, offset_minute = rest:match("^([%+%-])(%d%d):?(%d%d)")
    if sign then
        local offset = tonumber(offset_hour) * 3600 + tonumber(offset_minute) * 60
        epoch = epoch + (sign == "-" and offset or -offset)
    end
    return epoch
end

--- RFC 3339 in UTC, for timeMin/timeMax.
local function toRfc3339(epoch)
    return os.date("!%Y-%m-%dT%H:%M:%SZ", epoch)
end

--- Local-time YYYY-MM-DD, used to group the agenda into days.
local function localDayKey(epoch)
    return os.date("%Y-%m-%d", epoch)
end

--- The calendars on the account, most useful first.
function Gcal.calendars()
    local response, err = Account:request{
        url = Http.url(Const.CALENDAR_API .. "/users/me/calendarList", { minAccessRole = "reader" }),
    }
    if not response then return nil, err end

    local calendars = {}
    for _i, entry in ipairs(response.items or {}) do
        calendars[#calendars + 1] = {
            id      = entry.id,
            name    = entry.summaryOverride or entry.summary or entry.id,
            primary = entry.primary == true,
            hidden  = entry.selected == false,
        }
    end
    table.sort(calendars, function(a, b)
        if a.primary ~= b.primary then return a.primary end
        return a.name < b.name
    end)
    return calendars
end

local function normalize(event, calendar_name)
    local record = {
        id          = event.id,
        title       = event.summary or _("(no title)"),
        location    = event.location,
        description = event.description,
        link        = event.hangoutLink or event.htmlLink,
        status      = event.status,
        calendar    = calendar_name,
        attendees   = event.attendees,
    }
    if event.start and event.start.date then
        record.all_day = true
        record.day_key = event.start.date
        -- Google's end date for an all-day event is exclusive.
        record.end_day_key = event["end"] and event["end"].date or event.start.date
    else
        record.all_day = false
        record.start_epoch = Gcal.parseRfc3339(event.start and event.start.dateTime)
        record.end_epoch = Gcal.parseRfc3339(event["end"] and event["end"].dateTime)
        if not record.start_epoch then return nil end
        record.day_key = localDayKey(record.start_epoch)
    end
    return record
end

--- Adds one entry per day an all-day event covers, so it shows on each of them.
local function expandAllDay(record, out, horizon_key)
    local year, month, day = record.day_key:match("^(%d+)%-(%d+)%-(%d+)$")
    if not year then
        out[#out + 1] = record
        return
    end
    -- Noon UTC keeps the date stable while stepping a day at a time.
    local cursor = Gcal.timegm(tonumber(year), tonumber(month), tonumber(day), 12, 0, 0)
    local exclusive_end = record.end_day_key
    local emitted = 0
    for _step = 1, 60 do
        local key = os.date("!%Y-%m-%d", cursor)
        if key > horizon_key then break end
        if emitted > 0 and (not exclusive_end or key >= exclusive_end) then break end
        local copy = {}
        for k, v in pairs(record) do copy[k] = v end
        copy.day_key = key
        out[#out + 1] = copy
        emitted = emitted + 1
        cursor = cursor + 86400
    end
end

--[[--
Events across the given calendars within an explicit window, sorted for display.

An account with twenty calendars would otherwise mean twenty round trips per
view; batching makes it one. `Batch.fetch` falls back to sequential requests by
itself if the batch comes back unusable, so a partial result is still possible.

@tparam table calendar_ids list of calendar ids
@tparam number from_epoch, to_epoch window bounds
@treturn table list of normalized events, ordered by day then start time
--]]
function Gcal.range(calendar_ids, from_epoch, to_epoch)
    calendar_ids = calendar_ids or {}
    if #calendar_ids == 0 then return {} end
    local horizon_key = os.date("!%Y-%m-%d", to_epoch)

    local query = Http.encodeQuery{
        singleEvents = "true",
        orderBy      = "startTime",
        timeMin      = toRfc3339(from_epoch),
        timeMax      = toRfc3339(to_epoch),
        maxResults   = 250,
    }
    local items = {}
    for _i, calendar_id in ipairs(calendar_ids) do
        local escaped = socket_url.escape(calendar_id)
        items[#items + 1] = {
            path = "/calendar/v3/calendars/" .. escaped .. "/events?" .. query,
            url  = Const.CALENDAR_API .. "/calendars/" .. escaped .. "/events?" .. query,
        }
    end

    local responses, err = Batch.fetch(BATCH_URL, items, _("Fetching calendar… %1 of %2"))
    if not responses then return nil, err end

    local events = {}
    for index = 1, #items do
        local response = responses[index]
        if response then
            local calendar_name = response.summary or calendar_ids[index]
            for _j, item in ipairs(response.items or {}) do
                if item.status ~= "cancelled" then
                    local record = normalize(item, calendar_name)
                    if record and record.all_day then
                        expandAllDay(record, events, horizon_key)
                    elseif record then
                        events[#events + 1] = record
                    end
                end
            end
        else
            logger.warn("GoogleSuite: no events returned for calendar", calendar_ids[index])
        end
    end

    table.sort(events, function(a, b)
        if a.day_key ~= b.day_key then return a.day_key < b.day_key end
        if a.all_day ~= b.all_day then return a.all_day end
        return (a.start_epoch or 0) < (b.start_epoch or 0)
    end)
    return events
end

--- Local midnight for a day key. Anchored at noon and walked back twelve hours
--- so a DST transition at midnight cannot land the timestamp on the wrong day.
function Gcal.dayStart(day_key)
    local year, month, day = day_key:match("^(%d+)%-(%d+)%-(%d+)$")
    if not year then return nil end
    return os.time{ year = tonumber(year), month = tonumber(month),
                    day = tonumber(day), hour = 12 } - 12 * 3600
end

--[[--
The agenda window: the start of the current week through the end of the seventh
day ahead.

Deliberately bounded rather than a rolling "next N days". This window is what
the device reads when it is offline, so it has to be small enough to stay cheap
to fetch and store, and it should not accumulate events the user has already
lived through beyond the current week.

@treturn string first day key, string last day key (both inclusive)
--]]
function Gcal.windowKeys(start_dow, now)
    now = now or os.time()
    local today = os.date("%Y-%m-%d", now)
    local today_days = Gcal.dayKeyToDays(today)
    local lead = (Gcal.weekdayOf(today) - (start_dow or 2)) % 7
    return Gcal.daysToDayKey(today_days - lead), Gcal.daysToDayKey(today_days + 7)
end

--- The same window as epoch bounds, for timeMin/timeMax.
function Gcal.agendaWindow(start_dow, now)
    local first_key, last_key = Gcal.windowKeys(start_dow, now)
    return Gcal.dayStart(first_key), Gcal.dayStart(last_key) + 86400
end

--- Keeps only the events that fall inside the agenda window. Used to trim a
--- wider grid fetch down to what the Home page cache is allowed to hold.
function Gcal.withinWindow(events, start_dow, now)
    local first_key, last_key = Gcal.windowKeys(start_dow, now)
    local kept = {}
    for _i, event in ipairs(events or {}) do
        if event.day_key >= first_key and event.day_key <= last_key then
            kept[#kept + 1] = event
        end
    end
    return kept
end

--- True when a fetched range fully covers the agenda window, so its results can
--- replace the cache rather than truncate it.
function Gcal.coversWindow(first_fetched, last_fetched, start_dow, now)
    local first_key, last_key = Gcal.windowKeys(start_dow, now)
    return first_fetched <= first_key and last_fetched >= last_key
end

--- The rolling agenda, bounded by `Gcal.windowKeys`.
function Gcal.agenda(calendar_ids, start_dow)
    local from, to = Gcal.agendaWindow(start_dow)
    return Gcal.range(calendar_ids, from, to)
end

--- Every event touching a month grid, given its first and last day cells.
function Gcal.gridRange(calendar_ids, first_key, last_key)
    local from = Gcal.dayKeyToDays(first_key) * 86400
    local to = (Gcal.dayKeyToDays(last_key) + 1) * 86400
    -- Widen by a day either side so events in the viewer's local timezone that
    -- fall outside the UTC window are still returned.
    return Gcal.range(calendar_ids, from - 86400, to + 86400)
end

--- The next upcoming event, for the ZenOS home widget.
function Gcal.next(events)
    local now = os.time()
    local today = localDayKey(now)
    for _i, event in ipairs(events or {}) do
        if event.all_day then
            if event.day_key >= today then return event end
        elseif (event.end_epoch or event.start_epoch or 0) >= now then
            return event
        end
    end
end

return Gcal
