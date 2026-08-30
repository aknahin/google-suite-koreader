--[[--
Keeping the Home page widget current without anyone asking it to.

The widget only ever reads the disk cache, so "refresh" is two separate things
and they are worth keeping apart:

* **repaint** — re-read the cache and redraw. Free, and all that is needed after
  the user has been reading mail inside the plugin, since triage already wrote
  the cache on its way out.
* **fetch** — go to the network first. Costs radio time, so it is rate-limited
  and never happens unless the device is already connected.

The hard rule is that nothing here may prompt. `ui/task.lua` runs foreground
work through `NetworkMgr:runWhenOnline`, which will happily raise a Wi-Fi dialog
— exactly right when the user tapped something, exactly wrong on every wake-up.
So this path checks `isConnected()` and gives up quietly if the radio is off. A
Kindle spends most of its life that way, which means the periodic refresh is
usually a no-op costing one cheap check; that is the intended behaviour, not a
shortcoming. Turning the radio on by ourselves would be a battery bill the user
never agreed to.
--]]

local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local Account = require("lib/account")
local Cache = require("lib/cache")
local Gcal = require("lib/gcal")
local Gmail = require("lib/gmail")
local Http = require("lib/http")

local Sync = {}

--- Never fetch more often than this, whatever asks. Several triggers can fire
--- at once — a wake that also reconnects Wi-Fi, say — and one refresh is enough.
local MIN_FETCH_INTERVAL = 300

--- No popup is in front of a background fetch, so it must not be able to hang
--- the UI for long. Seconds.
local BACKGROUND_TIMEOUTS = { block = 10, total = 45 }

local INBOX_CACHE_KEY = "mail_inbox"
local AGENDA_CACHE_KEY = "agenda"
local CALENDARS_CACHE_KEY = "calendars"

local DEFAULT_INTERVAL_MINUTES = 30

local running = false
local last_fetch_at = 0

-- ---------------------------------------------------------------- settings ---

function Sync.settings()
    return Account:settings()
end

--- Auto-refresh is on unless it has been turned off. It is safe to leave on:
--- with the radio down it does nothing at all.
function Sync.isEnabled()
    return not Sync.settings():isFalse("auto_refresh")
end

--[[--
Off, then the intervals worth offering.

Nothing below five minutes, because `MIN_FETCH_INTERVAL` would swallow it; and
past two hours it is indistinguishable from off on a device that spends its life
asleep with the radio down.
--]]
Sync.INTERVALS = { 15, 30, 60, 120 }
Sync.DEFAULT_INTERVAL_MINUTES = DEFAULT_INTERVAL_MINUTES

--- Anything unusable — absent, not a number, too eager — becomes the default.
function Sync.normalizeInterval(value)
    local minutes = tonumber(value)
    if not minutes or minutes < 5 then return DEFAULT_INTERVAL_MINUTES end
    return math.floor(minutes)
end

function Sync.intervalMinutes()
    return Sync.normalizeInterval(Sync.settings():readSetting("auto_refresh_minutes"))
end

--[[--
The next state of the setting button: off, 15, 30, 60, 120, off again.

Pure, so the cycle can be tested without a settings file. Switching back on
lands on the default rather than resuming whatever was last set — coming out of
"off" is the moment someone wants the sensible value, not their old one.

@treturn boolean enabled, number minutes
--]]
function Sync.nextInterval(enabled, minutes)
    if not enabled then return true, DEFAULT_INTERVAL_MINUTES end
    local current = Sync.normalizeInterval(minutes)
    for index, candidate in ipairs(Sync.INTERVALS) do
        if candidate == current then
            local following = Sync.INTERVALS[index + 1]
            if following then return true, following end
            return false, DEFAULT_INTERVAL_MINUTES
        end
    end
    -- A value that is not on the list: put it back on one.
    return true, DEFAULT_INTERVAL_MINUTES
end

--- Applies `Sync.nextInterval` to the stored settings and restarts the timer.
function Sync.cycleInterval()
    local settings = Sync.settings()
    local enabled, minutes = Sync.nextInterval(Sync.isEnabled(), Sync.intervalMinutes())
    settings:saveSetting("auto_refresh", enabled)
    settings:saveSetting("auto_refresh_minutes", minutes)
    settings:flush()
    Sync.restartTimer()
    return enabled, minutes
end

-- ----------------------------------------------------------------- repaint ---

--[[--
Asks ZenOS to rebuild the Home page.

Re-registering is the trigger: the registry calls its refresh hook on every
register, and ZenOS's `rebuildActive` is safe whether or not the Home page is
actually on screen — when it is not, it just marks a rebuild as needed and does
it next time Home is shown.
--]]
function Sync.repaint()
    local ok, err = pcall(function()
        require("ui/homewidget").register()
    end)
    if not ok then logger.warn("GoogleSuite: home repaint failed", err) end
    return ok
end

-- ------------------------------------------------------------------- fetch ---

--- The calendars to read, from cache only: working out which calendars exist is
--- not worth a network round trip on a background refresh.
local function cachedCalendarIds()
    local chosen = Sync.settings():readSetting("calendar_ids")
    if type(chosen) == "table" and #chosen > 0 then return chosen end
    local calendars = Cache.get(CALENDARS_CACHE_KEY)
    if not calendars then return nil end
    local ids = {}
    for _i, calendar in ipairs(calendars) do
        if not calendar.hidden then ids[#ids + 1] = calendar.id end
    end
    return #ids > 0 and ids or nil
end

--- @treturn boolean whether anything was written
local function fetchInbox()
    local result, err = Gmail.list{ query = "in:inbox", max = 25 }
    if not result then
        logger.dbg("GoogleSuite: background inbox refresh failed", err)
        return false
    end
    Cache.set(INBOX_CACHE_KEY, result.messages)
    return true
end

local function fetchAgenda()
    local ids = cachedCalendarIds()
    if not ids then return false end
    local start_dow = Sync.settings():readSetting("week_start_dow") or 2
    local events, err = Gcal.agenda(ids, start_dow)
    if not events then
        logger.dbg("GoogleSuite: background agenda refresh failed", err)
        return false
    end
    Cache.set(AGENDA_CACHE_KEY, Gcal.withinWindow(events, start_dow))
    return true
end

--- True when both caches are younger than `max_age`, so there is nothing to do.
local function cachesAreFresh(max_age)
    local _inbox, inbox_age = Cache.get(INBOX_CACHE_KEY)
    local _agenda, agenda_age = Cache.get(AGENDA_CACHE_KEY)
    if not inbox_age or not agenda_age then return false end
    return inbox_age < max_age and agenda_age < max_age
end

--[[--
Refreshes what the Home page reads, then redraws it.

@tparam table opts
    max_age (number) seconds; skip the network if both caches are younger
    force   (bool)   the user asked: ignore the rate limit and the cache ages,
                     and take the long timeouts, since a popup is in front of it
    reason  (string) for the log only
@treturn boolean whether the network was actually used
--]]
function Sync.run(opts)
    opts = opts or {}
    -- Whatever happens next, show what is already on disk: triage inside the
    -- plugin has usually just changed it.
    Sync.repaint()

    if running then return false end
    if not Account:isConfigured() then return false end
    if Account.needs_reauth then return false end

    if not opts.force then
        local max_age = opts.max_age or MIN_FETCH_INTERVAL
        if os.time() - last_fetch_at < MIN_FETCH_INTERVAL then return false end
        if cachesAreFresh(max_age) then return false end
    end

    -- The cheap interface check, not isOnline(): that resolves a hostname,
    -- which is a network round trip of its own before we have decided to make
    -- any. A connection that is up but useless fails fast on the timeouts below.
    if not NetworkMgr:isConnected() then
        logger.dbg("GoogleSuite: skipping background refresh, radio is down")
        return false
    end

    running = true
    -- A forced refresh has a progress popup in front of it, so it can afford to
    -- wait like any other foreground request.
    Http.background_timeouts = not opts.force and BACKGROUND_TIMEOUTS or nil
    local ok, updated = pcall(function()
        -- Both are attempted even if the first fails: mail being unreachable is
        -- no reason to leave the agenda stale too.
        local got_mail = fetchInbox()
        local got_events = fetchAgenda()
        if got_mail or got_events then
            last_fetch_at = os.time()
            Sync.repaint()
            return true
        end
        return false
    end)
    Http.background_timeouts = nil
    running = false

    if not ok then
        logger.warn("GoogleSuite: background refresh errored", updated)
        return false
    end
    logger.dbg("GoogleSuite: background refresh done", opts.reason or "", updated)
    return updated
end

--- Runs the refresh off the current call stack, so whatever triggered it — a
--- wake-up, a page closing — finishes painting first.
function Sync.runSoon(opts, delay)
    UIManager:scheduleIn(delay or 2, function() Sync.run(opts) end)
end

-- ------------------------------------------------------------------- timer ---

--- A stable reference, so the tick can unschedule itself.
local tick

tick = function()
    if not Sync.isEnabled() then return end
    Sync.run{ max_age = Sync.intervalMinutes() * 60, reason = "timer" }
    UIManager:scheduleIn(Sync.intervalMinutes() * 60, tick)
end

--- (Re)starts the periodic refresh, or stops it if it has been turned off.
--- Idempotent: the pending tick is always dropped before another is scheduled.
function Sync.restartTimer()
    UIManager:unschedule(tick)
    if not Sync.isEnabled() then return false end
    UIManager:scheduleIn(Sync.intervalMinutes() * 60, tick)
    return true
end

function Sync.stopTimer()
    UIManager:unschedule(tick)
end

--- Exposed so the timer can be exercised without waiting on the clock.
Sync._tick = function() return tick() end

return Sync
