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

function hub.openMail()
    remember("mail")
    local MailList = require("ui/maillist")
    return MailList.new(hub):show()
end

function hub.openAgenda()
    remember("calendar")
    local Agenda = require("ui/agenda")
    return Agenda.new(hub):show()
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

return AppView
