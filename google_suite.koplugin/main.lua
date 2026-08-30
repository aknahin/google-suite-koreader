--[[--
Google Suite for KOReader: Gmail and Google Calendar.

ZenOS discovers launchable plugins in `modules/menu/app_launcher/plugin_scan.lua`
by probing for a callable `onShow`/`show`/`open`/`launch`/`onOpen`, or an
`addToMainMenu` entry with a callback. `GoogleSuite:show()` below is what makes
this plugin appear under *Zen Settings > Navbar > Tabs > Add > Plugin Menu*.
Note that the scanner calls `addToMainMenu` against a throwaway probe table, so
that method must stay free of side effects.
--]]

local Dispatcher = require("dispatcher")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local AppView = require("ui/appview")
local HomeWidget = require("ui/homewidget")
local Sync = require("lib/sync")

local GoogleSuite = WidgetContainer:extend{
    name = "google_suite",
    is_doc_only = false,
}

function GoogleSuite:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    HomeWidget.register()
    Sync.restartTimer()
end

--[[--
Waking up.

The Home page is the first thing a Kindle shows after a wake, and it draws from
a cache that may be hours old. The refresh is deferred a couple of seconds so
the wake-up paint happens first, and it gives up silently unless the radio is
already on — see lib/sync.lua.
--]]
function GoogleSuite:onResume()
    Sync.runSoon{ reason = "resume" }
    -- A suspend may have outlasted the pending tick.
    Sync.restartTimer()
end

function GoogleSuite:onSuspend()
    Sync.stopTimer()
end

--- Wi-Fi coming up is the one moment a fetch is certain to be possible.
function GoogleSuite:onNetworkConnected()
    Sync.runSoon{ reason = "network" }
end

--- Nothing in this plugin should outlive it.
function GoogleSuite:onCloseWidget()
    Sync.stopTimer()
end

function GoogleSuite:onDispatcherRegisterActions()
    Dispatcher:registerAction("google_suite_open", {
        category = "none",
        event = "OpenGoogleSuite",
        title = _("Google Suite"),
        general = true,
    })
end

function GoogleSuite:addToMainMenu(menu_items)
    menu_items.google_suite = {
        text = _("Google Suite"),
        sorting_hint = "tools",
        callback = function() self:show() end,
    }
end

--- Opens the plugin. Also the hook ZenOS's launcher looks for.
function GoogleSuite:show()
    AppView.open()
end

function GoogleSuite:onOpenGoogleSuite()
    self:show()
    return true
end

--- ZenOS broadcasts this if it finishes loading after us.
function GoogleSuite:onZenOSReady()
    HomeWidget.register()
end

--- Legacy alias still broadcast by ZenOS for older integrations.
function GoogleSuite:onZenUIReady()
    HomeWidget.register()
end

return GoogleSuite
