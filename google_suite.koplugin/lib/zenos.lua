--[[--
The ZenOS bridge: the globals ZenOS publishes, and nothing else.

Everything here is optional. With plain KOReader none of these globals exist and
every function degrades to the no-ZenOS answer, so nothing in the plugin has to
branch on whether ZenOS is installed.
--]]

local Device = require("device")
local logger = require("logger")

local Screen = Device.screen

local ZenOS = {}

--[[--
The height ZenOS's navigation bar occupies at the foot of the screen, or 0.

ZenOS draws the navbar as part of the FileManager sitting below us and publishes
the height it took in `__ZEN_UI_NAVBAR_HEIGHT`. Reserving that strip — rather
than painting over it — is what makes the bar show through and stay tappable:
gestures we do not consume fall down the window stack to the FileManager, which
owns the bar.

Reserving is the only option open to us. ZenOS builds the bar inside a closure
in its navbar patch and injects it only into views it owns, chosen from a
hardcoded list of its own page names; there is no entry point for a third-party
plugin to mount a real navbar of its own.
--]]
function ZenOS.navbarHeight()
    local height = rawget(_G, "__ZEN_UI_NAVBAR_HEIGHT")
    if type(height) ~= "number" or height <= 0 then return 0 end
    -- A bar taller than a third of the screen is a stale or bogus reading, and
    -- honouring it would carve the page down to nothing.
    if height > Screen:getHeight() / 3 then
        logger.warn("GoogleSuite: implausible ZenOS navbar height", height)
        return 0
    end
    return math.floor(height)
end

--- The height a full-screen page should take, leaving the navbar visible.
function ZenOS.pageHeight()
    return Screen:getHeight() - ZenOS.navbarHeight()
end

--- False while a strip is being left for the navbar: the page no longer covers
--- the screen, so UIManager must keep painting what is underneath it.
function ZenOS.coversFullscreen()
    return ZenOS.navbarHeight() == 0
end

return ZenOS
