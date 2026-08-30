--[[--
Entry point and section switching.

The plugin opens straight into whichever section was used last, rather than a
hub screen — one tap saved on every launch, which matters on e-ink. Each section
carries a title-bar menu for switching to the other.
--]]

local Account = require("lib/account")
local Setup = require("ui/setup")

local AppView = {}

local hub = {}

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
