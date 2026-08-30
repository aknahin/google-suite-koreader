--[[--
The calendar section: agenda list, week grid, month grid.

One controller owns all three so the chosen view, the fetched events and the
selected calendars survive switching between them. The grids force landscape by
default, because seven columns on a 6" screen in portrait leaves ~150px each.
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local util = require("util")
local T = require("ffi/util").template
local _ = require("gettext")

local Account = require("lib/account")
local Cache = require("lib/cache")
local CalendarGrid = require("ui/calendargrid")
local EventList = require("ui/eventlist")
local Navbar = require("ui/navbar")
local Fmt = require("lib/fmt")
local Gcal = require("lib/gcal")
local Task = require("ui/task")

local Screen = Device.screen

local Agenda = {}
Agenda.__index = Agenda

local CALENDARS_CACHE_KEY = "calendars"
local AGENDA_CACHE_KEY = "agenda"

-- Cached events never expire. A Kindle is offline most of the time, so an old
-- agenda is the difference between reading something and reading nothing; the
-- fetch that follows replaces it when there is a radio. Anything older than
-- this is labelled instead of discarded.
local FRESH_FOR = 900

--- @tparam string|nil mode forces "list"/"week"/"month" for this visit only
function Agenda.new(hub, mode)
    return setmetatable({
        hub = hub, events = {}, events_by_day = {}, forced_mode = mode,
    }, Agenda)
end

function Agenda:settings()
    return Account:settings()
end

--- A forced mode wins until the user picks one themselves, so arriving here
--- from the Home page or the mail button does not rewrite their default view.
function Agenda:mode()
    return self.forced_mode or self:settings():readSetting("calendar_view") or "list"
end

function Agenda:startDow()
    return self:settings():readSetting("week_start_dow") or 2
end

--- Calendar ids the user has chosen, defaulting to every visible calendar.
function Agenda:selectedCalendarIds(calendars)
    local chosen = self:settings():readSetting("calendar_ids")
    if type(chosen) == "table" and #chosen > 0 then return chosen end
    local ids = {}
    for _i, calendar in ipairs(calendars or {}) do
        if not calendar.hidden then ids[#ids + 1] = calendar.id end
    end
    return ids
end

--- Fetches the calendar list once a week and remembers it.
function Agenda:ensureCalendars()
    if self.calendars then return self.calendars end
    local cached = Cache.get(CALENDARS_CACHE_KEY, 7 * 86400)
    if cached then
        self.calendars = cached
        return cached
    end
    local fetched, err = Gcal.calendars()
    if not fetched then return nil, err end
    Cache.set(CALENDARS_CACHE_KEY, fetched)
    self.calendars = fetched
    return fetched
end

--[[--
Refreshes the cache the ZenOS Home page reads.

The Home page has no network of its own and only ever reads `agenda`, so every
successful fetch feeds it — otherwise a user who lives in the month grid would
never write that key at all, and Home would sit on "Nothing scheduled" forever.
Trimmed to the agenda window so the grid's wider range does not push months of
events into a file the Home page has to load on every wake.

@tparam string first_key, last_key the range that was actually fetched
--]]
function Agenda:saveHomeAgenda(events, first_key, last_key)
    local start_dow = self:startDow()
    local covers = Gcal.coversWindow(first_key, last_key, start_dow)
    -- A partial window still beats an empty Home page on a fresh install.
    if not covers and Cache.get(AGENDA_CACHE_KEY) then return end
    Cache.set(AGENDA_CACHE_KEY, Gcal.withinWindow(events, start_dow))
end

-- ---------------------------------------------------------------- periods ---

function Agenda:anchorKey()
    if not self.anchor then self.anchor = os.date("%Y-%m-%d") end
    return self.anchor
end

--- Moves the anchor a whole period at a time; month steps land on the 1st so a
--- 31st never skips a short month.
function Agenda:shiftAnchor(step)
    if self:mode() == "week" then
        self.anchor = Gcal.daysToDayKey(Gcal.dayKeyToDays(self:anchorKey()) + step * 7)
        return
    end
    local year, month = self:anchorKey():match("^(%d%d%d%d)%-(%d%d)")
    year, month = tonumber(year), tonumber(month) + step
    while month > 12 do year, month = year + 1, month - 12 end
    while month < 1 do year, month = year - 1, month + 12 end
    self.anchor = string.format("%04d-%02d-01", year, month)
end

--- The day cells of the current period, and a stable cache key for them.
function Agenda:period()
    local cells
    if self:mode() == "week" then
        cells = Gcal.weekDays(self:anchorKey(), self:startDow())
    else
        local year, month = self:anchorKey():match("^(%d%d%d%d)%-(%d%d)")
        cells = Gcal.monthDays(tonumber(year), tonumber(month), self:startDow())
    end
    return cells, "grid_" .. self:mode() .. "_" .. cells[1].key
end

function Agenda:gridTitle(cells)
    if self:mode() == "week" then
        return Fmt.weekTitle(cells[1].key, cells[#cells].key)
    end
    local year, month = self:anchorKey():match("^(%d%d%d%d)%-(%d%d)")
    return Fmt.monthTitle(tonumber(year), tonumber(month))
end

-- --------------------------------------------------------------- rotation ---

--- @treturn boolean whether the screen was actually turned
function Agenda:enterLandscape()
    if self:settings():isFalse("grid_landscape") then return false end
    if Screen:getWidth() >= Screen:getHeight() then return false end -- already landscape
    self.rotation_backup = Screen:getRotationMode()
    Screen:setRotationMode(Screen.DEVICE_ROTATED_CLOCKWISE)
    self.rotated = true
    return true
end

function Agenda:restoreRotation()
    if self.suppress_restore then return end
    if self.rotation_backup and self.rotation_backup ~= Screen:getRotationMode() then
        Screen:setRotationMode(self.rotation_backup)
    end
    self.rotation_backup = nil
    self.rotated = nil
end

-- ------------------------------------------------------------- list view ---

--- The window the list covers, spelled out because it is fixed rather than
--- chosen: this week, plus the next seven days.
function Agenda:listTitle()
    return _("Agenda")
end

--- "cached 3 Sep" while showing events that predate the last successful fetch.
function Agenda:staleLabel()
    if not self.stale_age then return nil end
    return T(_("cached %1"), Fmt.shortDate(os.time() - self.stale_age))
end

function Agenda:refreshList()
    if not self.list then return end
    self.list.subtitle = self:staleLabel()
    self.list:setEvents(self.events, self:listTitle())
end

function Agenda:loadList(force)
    local cached, age = Cache.get(AGENDA_CACHE_KEY)
    if cached and not force then
        self.events = cached
        self.stale_age = age > FRESH_FOR and age or nil
        self:refreshList()
    end

    Task.run(_("Fetching agenda…"), function()
        local calendars, err = self:ensureCalendars()
        if not calendars then return nil, err end
        return Gcal.agenda(self:selectedCalendarIds(calendars), self:startDow())
    end, function(events, err)
        if not events then
            if #self.events == 0 then Task.error(err) else Task.notify(err) end
            return
        end
        self.events = events
        self.stale_age = nil
        local first_key, last_key = Gcal.windowKeys(self:startDow())
        self:saveHomeAgenda(events, first_key, last_key)
        self:refreshList()
    end)
end

function Agenda:showList()
    self.list = EventList:new{
        title = self:listTitle(),
        subtitle = self:staleLabel(),
        events = self.events,
        on_menu = function() self:openNavMenu() end,
        on_event_tap = function(event) self:showEvent(event) end,
        on_section_switch = function() self:openMail() end,
        on_zen_navigate = function(tab_id)
            Navbar.navigate(function() self:close() end, tab_id)
        end,
        close_callback = function()
            self.list = nil
            self:close()
        end,
    }
    UIManager:show(self.list)
    self:loadList()
    return self.list
end

-- ------------------------------------------------------------- grid views ---

function Agenda:loadGrid(force)
    local cells, cache_key = self:period()
    local cached, age = Cache.get(cache_key)
    if cached and not force then
        self.events_by_day = Gcal.bucketByDay(cached)
        self.stale_age = age > FRESH_FOR and age or nil
        self:refreshGrid(cells)
    end

    Task.run(_("Fetching calendar…"), function()
        local calendars, err = self:ensureCalendars()
        if not calendars then return nil, err end
        return Gcal.gridRange(self:selectedCalendarIds(calendars),
                              cells[1].key, cells[#cells].key)
    end, function(events, err)
        if not events then
            if next(self.events_by_day) == nil then Task.error(err) else Task.notify(err) end
            return
        end
        Cache.set(cache_key, events)
        self:saveHomeAgenda(events, cells[1].key, cells[#cells].key)
        self.events_by_day = Gcal.bucketByDay(events)
        self.stale_age = nil
        self:refreshGrid(cells)
    end)
end

--- Re-lays the open grid out in place; the widget rebuilds itself from init().
function Agenda:refreshGrid(cells)
    if not self.grid then return end
    cells = cells or self:period()
    self.grid.anchor = self:anchorKey()
    self.grid.mode = self:mode()
    self.grid.start_dow = self:startDow()
    self.grid.events_by_day = self.events_by_day
    self.grid.title = self:gridTitle(cells)
    self.grid:init()
    UIManager:setDirty(self.grid, "full")
end

function Agenda:showGrid()
    self:enterLandscape()
    local cells = self:period()
    self.grid = CalendarGrid:new{
        mode = self:mode(),
        anchor = self:anchorKey(),
        start_dow = self:startDow(),
        events_by_day = self.events_by_day,
        title = self:gridTitle(cells),
        on_menu = function() self:openNavMenu() end,
        on_section_switch = function() self:openMail() end,
        on_zen_navigate = function(tab_id)
            Navbar.navigate(function() self:close() end, tab_id)
        end,
        on_day_tap = function(day_key) self:showDay(day_key) end,
        on_navigate = function(step)
            self:shiftAnchor(step)
            self.events_by_day = {}
            self:refreshGrid()
            self:loadGrid()
        end,
        close_callback = function()
            self.grid = nil
            self:restoreRotation()
        end,
    }
    UIManager:show(self.grid)
    self:loadGrid()
    return self.grid
end

--- One day's events, opened by tapping a grid cell. Same cards as the agenda,
--- minus the day headings, which would repeat the title on every card.
function Agenda:showDay(day_key)
    local day_list
    day_list = EventList:new{
        title = Fmt.dayHeading(day_key),
        events = self.events_by_day[day_key] or {},
        day_headings = false,
        on_event_tap = function(event) self:showEvent(event) end,
        close_callback = function() self.day_list = nil end,
    }
    self.day_list = day_list
    UIManager:show(day_list)
end

-- ------------------------------------------------------------------ shared ---

function Agenda:showEvent(event)
    local lines = {}
    if event.all_day then
        lines[#lines + 1] = T(_("When: %1 (all day)"), Fmt.dayHeading(event.day_key))
    else
        lines[#lines + 1] = T(_("When: %1 – %2"),
                              Fmt.dayHeading(event.day_key) .. ", "
                                  .. Fmt.clock12(event.start_epoch),
                              Fmt.clock12(event.end_epoch))
    end
    lines[#lines + 1] = T(_("Calendar: %1"), event.calendar or "")
    if event.location and event.location ~= "" then
        lines[#lines + 1] = T(_("Where: %1"), event.location)
    end
    if event.link then
        lines[#lines + 1] = T(_("Link: %1"), event.link)
    end
    if event.attendees and #event.attendees > 0 then
        local names = {}
        for _i, attendee in ipairs(event.attendees) do
            names[#names + 1] = attendee.displayName or attendee.email or "?"
        end
        lines[#lines + 1] = T(_("Attendees: %1"), table.concat(names, ", "))
    end
    if event.description and event.description ~= "" then
        lines[#lines + 1] = ""
        lines[#lines + 1] = util.htmlToPlainTextIfHtml(event.description)
    end

    UIManager:show(TextViewer:new{
        title = event.title,
        text = table.concat(lines, "\n"),
        text_type = "file_content",
    })
end

--- Lets the user pick which calendars feed the views.
function Agenda:chooseCalendars()
    if not self.calendars then
        Task.notify(_("Calendars are still loading."))
        return
    end
    local selected = {}
    for _i, id in ipairs(self:selectedCalendarIds(self.calendars)) do selected[id] = true end

    local dialog
    local buttons = {}
    for _i, calendar in ipairs(self.calendars) do
        local id = calendar.id
        buttons[#buttons + 1] = { {
            text = (selected[id] and "☑ " or "☐ ") .. calendar.name,
            align = "left",
            callback = function()
                selected[id] = not selected[id]
                local ids = {}
                for _j, entry in ipairs(self.calendars) do
                    if selected[entry.id] then ids[#ids + 1] = entry.id end
                end
                self:settings():saveSetting("calendar_ids", ids)
                self:settings():flush()
                UIManager:close(dialog)
                self:chooseCalendars()
            end,
        } }
    end
    buttons[#buttons + 1] = { {
        text = _("Done"),
        align = "left",
        callback = function()
            UIManager:close(dialog)
            -- Only the calendar views are invalidated; the inbox cache is untouched.
            Cache.clear(AGENDA_CACHE_KEY)
            Cache.clear("grid_")
            self.events, self.events_by_day = {}, {}
            self:reload(true)
        end,
    } }

    dialog = ButtonDialog:new{ title = _("Calendars"), buttons = buttons,
                               shrink_unneeded_width = true }
    UIManager:show(dialog)
end

--- Leaves the calendar for the mail the user is most likely after.
function Agenda:openMail()
    self:close()
    self.hub.openMail("unread")
end

function Agenda:reload(force)
    if self:mode() == "list" then self:loadList(force) else self:loadGrid(force) end
end

--- Switches view without losing the anchor or the fetched calendar list.
--- Grid-to-grid keeps the landscape rotation, so week/month switching does not
--- flicker through portrait and back.
function Agenda:switchMode(mode)
    local previous = self:mode()
    if mode == previous then return end
    self.forced_mode = nil
    self:settings():saveSetting("calendar_view", mode)
    self:settings():flush()
    local both_grids = previous ~= "list" and mode ~= "list"
    self:close(both_grids)
    self.events, self.events_by_day, self.stale_age = {}, {}, nil
    self:show()
end

function Agenda:openNavMenu()
    local dialog
    local current = self:mode()
    local function mode_button(label, mode)
        return { {
            text = (current == mode and "● " or "○ ") .. label,
            align = "left",
            callback = function()
                UIManager:close(dialog)
                self:switchMode(mode)
            end,
        } }
    end

    local buttons = {
        mode_button(_("List"), "list"),
        mode_button(_("Week"), "week"),
        mode_button(_("Month"), "month"),
        { { text = _("Today"), align = "left", callback = function()
            UIManager:close(dialog)
            self.anchor = os.date("%Y-%m-%d")
            if current ~= "list" then
                self.events_by_day = {}
                self:refreshGrid()
            end
            self:reload()
        end } },
        { { text = _("Refresh"), align = "left",
            callback = function() UIManager:close(dialog) self:reload(true) end } },
        { { text = _("Choose calendars"), align = "left",
            callback = function() UIManager:close(dialog) self:chooseCalendars() end } },
        { { text = _("Mail"), align = "left", callback = function()
            UIManager:close(dialog)
            self:close()
            self.hub.openMail()
        end } },
        { { text = _("Unread mail"), align = "left", callback = function()
            UIManager:close(dialog)
            self:openMail()
        end } },
        { { text = _("Settings"), align = "left",
            callback = function() UIManager:close(dialog) self.hub.openSettings() end } },
    }
    dialog = ButtonDialog:new{ title = _("Calendar"), buttons = buttons,
                               shrink_unneeded_width = true }
    UIManager:show(dialog)
end

function Agenda:close(keep_rotation)
    if keep_rotation then
        -- Stop the grid's close_callback from putting portrait back.
        self.suppress_restore = true
    end
    if self.day_list then
        local day_list = self.day_list
        self.day_list = nil
        UIManager:close(day_list)
    end
    if self.list then
        local list = self.list
        self.list = nil
        UIManager:close(list)
    end
    if self.grid then
        UIManager:close(self.grid)
        self.grid = nil
    end
    self.suppress_restore = nil
    if not keep_rotation then self:restoreRotation() end
end

function Agenda:show()
    if self:mode() == "list" then return self:showList() end
    return self:showGrid()
end

return Agenda
