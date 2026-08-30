--[[--
The ZenOS bridge: the globals ZenOS publishes, and nothing else.

Everything here is optional. With plain KOReader none of these globals exist and
every function degrades to the no-ZenOS answer, so nothing in the plugin has to
branch on whether ZenOS is installed.
--]]

local Device = require("device")
local logger = require("logger")
local _ = require("gettext")

local Screen = Device.screen

local ZenOS = {}

--[[--
How tall to draw our own navigation bar, matching ZenOS's, or 0 for none.

An earlier attempt left ZenOS's real bar showing through a gap at the foot of
the page. It looked right and was completely dead: `UIManager:sendEvent` gives
the event to the topmost widget and then only to widgets flagged
`is_always_active` or registered as `active_widgets`, and the FileManager that
owns the bar is neither — so a tap on it went nowhere. A bar has to be *inside*
the page that is on top, which is what `ui/navbar.lua` builds.

The height still comes from `__ZEN_UI_NAVBAR_HEIGHT`, so ours is the same size
as the one on every other ZenOS page and the pages line up.
--]]
function ZenOS.navbarHeight()
    if not ZenOS.tabs() then return 0 end
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

-- ------------------------------------------------------------------- tabs ---

--[[--
The built-in tabs, mirrored from zenos.koplugin's navbar patch.

ZenOS keeps its tab table in a closure and publishes only the config and the
"open this tab" entry point, so the id → icon/label mapping has to be repeated
here. Labels are the English defaults; ZenOS translates its own, and an id that
gains a different icon upstream will simply show the old one rather than break.
--]]
local BUILTIN_TABS = {
    books          = { icon = "library",       label = _("Library") },
    folder         = { icon = "tab_folder",    label = _("Folder") },
    manga          = { icon = "tab_manga",     label = _("Manga") },
    news           = { icon = "tab_news",      label = _("News") },
    continue       = { icon = "book.opened",   label = _("Continue") },
    history        = { icon = "tab_history",   label = _("History") },
    favorites      = { icon = "star.empty",    label = _("Favorites") },
    collections    = { icon = "tab_collections", label = _("Collections") },
    authors        = { icon = "tab_authors",   label = _("Authors") },
    series         = { icon = "tab_series",    label = _("Series") },
    tags           = { icon = "tab_tags",      label = _("Tags") },
    to_be_read     = { icon = "tab_to_be_read", label = _("To Be Read") },
    home           = { icon = "home",          label = _("Home") },
    search         = { icon = "appbar.search", label = _("Search") },
    calibre_search = { icon = "appbar.search", label = _("Search") },
    stats          = { icon = "tab_stats",     label = _("Stats") },
    exit           = { icon = "tab_exit",      label = _("Exit") },
    page_left      = { icon = "tab_left",      label = _("Prev") },
    page_right     = { icon = "tab_right",     label = _("Next") },
    menu           = { icon = "appbar.menu",   label = _("Menu") },
}

--- Tabs ZenOS would act on from one of its own pages but cannot from ours: they
--- page or navigate the file list, which is not what is on screen.
local SKIP_TABS = { page_left = true, page_right = true }

local function navbarConfig()
    local plugin = rawget(_G, "__ZEN_UI_PLUGIN")
    local config = plugin and plugin.config and plugin.config.navbar
    if type(config) ~= "table" then return nil end
    return config
end

--- A tab ZenOS was configured with but we have no built-in entry for.
local function customTab(config, id)
    for _i, tab in ipairs(config.custom_tabs or {}) do
        if type(tab) == "table" and tab.id == id then
            return {
                id    = id,
                icon  = tab.icon or "zen_ui",
                label = (tab.label ~= nil and tab.label ~= "") and tab.label
                    or tab.tag or tab.plugin_title or _("Custom"),
            }
        end
    end
end

--[[--
The tabs to draw, in ZenOS's configured order, or nil when ZenOS is absent.

@treturn table|nil list of { id, icon, label }, and the config that produced it
--]]
function ZenOS.tabs()
    if type(rawget(_G, "__ZEN_UI_NAVBAR_OPEN_TAB")) ~= "function" then return nil end
    local config = navbarConfig()
    if not config or type(config.tab_order) ~= "table" then return nil end

    local tabs = {}
    for _i, id in ipairs(config.tab_order) do
        if not SKIP_TABS[id] then
            local builtin = BUILTIN_TABS[id]
            local tab = builtin
                and { id = id, icon = builtin.icon, label = builtin.label }
                or customTab(config, id)
            -- ZenOS lets these two be renamed; everything else keeps its label.
            if tab and id == "books" and config.books_label ~= "" then
                tab.label = config.books_label
            elseif tab and id == "home" and config.home_label ~= "" then
                tab.label = config.home_label
            end
            if tab then tabs[#tabs + 1] = tab end
        end
    end
    if #tabs == 0 then return nil end
    return tabs, config
end

--- Hands navigation back to ZenOS. Returns false if it would not go.
function ZenOS.openTab(tab_id)
    local open = rawget(_G, "__ZEN_UI_NAVBAR_OPEN_TAB")
    if type(open) ~= "function" then return false end
    local ok, result = pcall(open, tab_id)
    if not ok then
        logger.warn("GoogleSuite: ZenOS refused tab", tab_id, result)
        return false
    end
    return true
end

return ZenOS
