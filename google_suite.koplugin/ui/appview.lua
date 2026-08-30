--[[--
Entry point and section switching.

The plugin opens straight into whichever section was used last, rather than a
hub screen — one tap saved on every launch, which matters on e-ink. Each section
carries a title-bar menu for switching to the other.
--]]

local UIManager = require("ui/uimanager")

local Account = require("lib/account")
local Setup = require("ui/setup")

local AppView = {}

local hub = {}

--[[--
Leaving the plugin.

Sections call `close()` when they are switched as well as when they are
dismissed, so "the plugin was closed" cannot be read from a single close. The
refresh is scheduled a moment out instead, and any section appearing cancels it
— what survives that delay is a real exit. The signal is a section *showing*
rather than the hub being asked to open one, because switching calendar views
re-shows without coming back through the hub.

The repaint is the point of it. Reading and triaging mail rewrites the cache the
Home widget draws from, so leaving is exactly when the Home page is most likely
to be showing a count that is no longer true.
--]]
local pending_exit

local function cancelExit()
    if not pending_exit then return end
    UIManager:unschedule(pending_exit)
    pending_exit = nil
end

--- Called by every section as it appears.
function hub.notifyOpened()
    cancelExit()
end

--- Called by every section as it closes.
function hub.notifyClosed()
    cancelExit()
    pending_exit = function()
        pending_exit = nil
        require("lib/sync").run{ reason = "left plugin" }
    end
    UIManager:scheduleIn(1, pending_exit)
end

local function remember(section)
    local settings = Account:settings()
    settings:saveSetting("last_section", section)
    settings:flush()
end

--- @tparam string|nil view_key one of MailList.VIEWS, e.g. "unread"
function hub.openMail(view_key)
    remember("mail")
    local MailList = require("ui/maillist")
    return MailList.new(hub, view_key):show()
end

--- @tparam string|nil mode "list", "week" or "month", for this visit only; the
--- saved calendar_view is left alone so a jump here does not become the default.
function hub.openAgenda(mode)
    remember("calendar")
    local Agenda = require("ui/agenda")
    return Agenda.new(hub, mode):show()
end

function hub.openSettings()
    Setup.show(function() AppView.open() end)
end

--- Opens the plugin; the only function main.lua needs.
function AppView.open()
    Setup.applyPreferences()
    if not Account:isConfigured() then
        Setup.showOnboarding(function() AppView.open() end)
        return
    end
    if Account:settings():readSetting("last_section") == "calendar" then
        return hub.openAgenda()
    end
    return hub.openMail()
end

AppView.notifyClosed = hub.notifyClosed
AppView.notifyOpened = hub.notifyOpened
AppView.openMail = hub.openMail
AppView.openAgenda = hub.openAgenda
AppView.openSettings = hub.openSettings

--[[--
Opens straight to a section, for the ZenOS Home widget.

The Home page can be showing while the plugin is not, so this runs the same
sign-in guard `AppView.open` does rather than assuming an account exists.
--]]
function AppView.openSection(section, target)
    Setup.applyPreferences()
    if not Account:isConfigured() then
        Setup.showOnboarding(function() AppView.open() end)
        return
    end
    if section == "calendar" then return hub.openAgenda(target) end
    return hub.openMail(target)
end

return AppView
