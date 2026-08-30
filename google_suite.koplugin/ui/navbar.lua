--[[--
A ZenOS navigation bar for our own pages.

Reserving a strip and letting ZenOS's real bar show through underneath does not
work: `UIManager:sendEvent` hands the event to the topmost widget and then only
to widgets flagged `is_always_active` or registered as `active_widgets`, and the
FileManager that owns the bar is neither. The bar was visible and completely
dead. So the bar has to live inside the page that is on top — this one.

It is drawn from ZenOS's own configuration (`__ZEN_UI_PLUGIN.config.navbar`, via
`lib/zenos.lua`) so it carries the same tabs in the same order at the same
height, and every tap is handed straight back to ZenOS through
`__ZEN_UI_NAVBAR_OPEN_TAB`. What it deliberately does not do is track the active
tab: none of these tabs is what is on screen while our plugin is open, so
highlighting one would be a lie.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")

local ZenOS = require("lib/zenos")

local Screen = Device.screen

local Navbar = {}

--- ZenOS's icons are registered into KOReader's icon cache at startup, so they
--- resolve by name — but an unknown name renders "icon not found" rather than
--- failing, so a tab whose icon we cannot size is drawn as its label alone.
local function icon(name, size)
    if not name or size < 1 then return nil end
    local ok, widget = pcall(IconWidget.new, IconWidget, {
        icon = name, width = size, height = size, alpha = true,
    })
    if ok and widget then return widget end
    logger.dbg("GoogleSuite: navbar icon unavailable", name)
end

local function tabCell(tab, width, height, config)
    local padding = Size.padding.small
    local show_labels = config.show_labels ~= false
    local show_icons = config.show_icons ~= false

    local group = VerticalGroup:new{ align = "center" }
    local label_height = 0
    local label
    if show_labels then
        label = TextWidget:new{
            text = tab.label or tab.id,
            face = Font:getFace("xx_smallinfofont"),
            max_width = width - 2 * padding,
        }
        label_height = label:getSize().h
    end

    if show_icons then
        -- Whatever is left after the label, so the cell always fits the height
        -- ZenOS published rather than growing the bar.
        local size = height - 2 * padding - label_height
            - (label and Size.padding.tiny or 0)
        local glyph = icon(tab.icon, size)
        if glyph then
            table.insert(group, glyph)
            if label then table.insert(group, VerticalSpan:new{ width = Size.padding.tiny }) end
        end
    end
    if label then table.insert(group, label) end

    return CenterContainer:new{
        dimen = Geom:new{ w = width, h = height },
        group,
    }
end

--[[--
The bar, or nil when ZenOS is not there to navigate to.

@tparam number width the page width
@tparam function on_navigate called with a tab id; the page should close itself
        first (restoring any rotation it forced) and then hand over
@treturn widget|nil bar, number height
--]]
function Navbar.build(width, on_navigate)
    local height = ZenOS.navbarHeight()
    if height == 0 then return nil end
    local tabs, config = ZenOS.tabs()
    if not tabs then return nil end

    local rule = math.max(Size.line.medium or 1, 1)
    local row_height = height - rule
    local cell_width = math.floor(width / #tabs)

    local row = HorizontalGroup:new{ align = "center" }
    for _i, tab in ipairs(tabs) do
        table.insert(row, tabCell(tab, cell_width, row_height, config))
    end

    local bar = InputContainer:new{
        dimen = Geom:new{ w = width, h = height },
    }
    bar.ges_events = {
        TapZenNavbar = {
            -- The bar is built before it is placed, so the range cannot be its
            -- final position; it is the screen, and the hit test below uses the
            -- dimen that InputContainer:paintTo fills in.
            GestureRange:new{ ges = "tap", range = Geom:new{
                x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight(),
            } },
        },
    }
    bar.onTapZenNavbar = function(self, _arg, ges)
        if not (self.dimen and ges and ges.pos and self.dimen:contains(ges.pos)) then
            return false
        end
        local index = math.floor((ges.pos.x - self.dimen.x) / cell_width) + 1
        if index < 1 then index = 1 end
        if index > #tabs then index = #tabs end
        on_navigate(tabs[index].id)
        return true
    end
    bar[1] = VerticalGroup:new{
        align = "left",
        LineWidget:new{
            dimen = Geom:new{ w = width, h = rule },
            background = Blitbuffer.COLOR_GRAY,
        },
        row,
    }
    return bar, height
end

--[[--
Puts the bar under a KOReader `Menu`, which builds its own layout.

The menu is created at `Navbar.bodyHeight()` and then has its single child
wrapped in a group with the bar below it — the same move ZenOS makes for its own
standalone pages. `dimen` is stretched back over the bar afterwards so repaints
and gestures cover the whole screen.

@treturn boolean whether a bar was attached
--]]
function Navbar.attachToMenu(menu, on_navigate)
    if not (menu and menu[1]) then return false end
    local bar, height = Navbar.build(Screen:getWidth(), on_navigate)
    if not bar then return false end

    menu[1] = VerticalGroup:new{
        align = "left",
        menu[1],
        bar,
    }
    if menu.dimen then menu.dimen.h = Screen:getHeight() end
    menu.covers_fullscreen = true
    if menu.resetLayout then menu:resetLayout() end
    return true
end

--- The height a page body may take once the bar has had its share.
function Navbar.bodyHeight()
    return Screen:getHeight() - ZenOS.navbarHeight()
end

--- Closes the page, then asks ZenOS to go. Closing first matters for the grids,
--- whose close path puts the screen rotation back.
function Navbar.navigate(close, tab_id)
    close()
    ZenOS.openTab(tab_id)
end

return Navbar
