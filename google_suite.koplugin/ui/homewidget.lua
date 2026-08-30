--[[--
The ZenOS Home page widget: two boxes, unread mail and the next event.

    ┌──────────┐ ┌────────────────────────────────────┐
    │  ✉   4   │ │  📅  5:20 PM  Design review        │
    └──────────┘ └────────────────────────────────────┘

Reads only from the cache — the Home page is drawn on every wake, and it must
never wait on the radio, so the unread count is derived from the last synced
inbox rather than from a Gmail label lookup, and the next event from the agenda
`ui/agenda.lua` writes after every fetch. Registration is guarded because ZenOS
may load before or after this plugin; `main.lua` also calls this from the
`ZenOSReady` handler.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local logger = require("logger")
local _ = require("gettext")

local Cache = require("lib/cache")
local Fmt = require("lib/fmt")
local Gcal = require("lib/gcal")

local HomeWidget = {}

local ITEM_ID = "google_suite.summary"

--- The unread box is sized to its content; whatever is left goes to the event
--- box, which is the one with something to say.
local MAIL_BOX_FRACTION = 0.28

--[[--
An icon, tried against several names.

KOReader's icon set is not versioned with this plugin and the names have moved
between releases, so each box names its candidates in preference order and the
box simply goes without if none of them resolve. A missing icon must not be able
to take the Home page down with it.
--]]
local function icon(names, size)
    for _i, name in ipairs(names) do
        local ok, widget = pcall(function()
            return IconWidget:new{
                icon = name,
                width = size,
                height = size,
                alpha = true,
            }
        end)
        if ok and widget then return widget end
    end
    logger.dbg("GoogleSuite: no home icon matched", table.concat(names, ", "))
    return nil
end

local MAIL_ICONS = { "email", "appbar.email", "mail", "appbar.mail" }
local CALENDAR_ICONS = { "calendar", "appbar.calendar", "appbar.date", "clock" }

--- Unread messages in the last synced inbox, or nil when it has never synced.
local function unreadCount()
    local messages = Cache.get("mail_inbox")
    if not messages then return nil end
    local unread = 0
    for _i, message in ipairs(messages) do
        if message.unread then unread = unread + 1 end
    end
    return unread
end

--- The next event's time and title, as two strings for the event box.
local function nextEventLabels()
    local events = Cache.get("agenda")
    local event = events and Gcal.next(events)
    if not event then return nil end
    local when = event.all_day and _("All day") or Fmt.clock12(event.start_epoch)
    -- The day only earns its place when it is not today; on the Home page the
    -- time is what the user is scanning for.
    local today = os.date("%Y-%m-%d")
    if event.day_key ~= today then
        when = Fmt.dayHeading(event.day_key) .. " " .. when
    end
    return when, event.title
end

--- One box: icon on the left, a stack of lines on the right.
local function box(width, height, icon_names, lines)
    local padding = Size.padding.default
    local border = Size.border.thin
    local inner_height = height - 2 * (padding + border)
    local icon_size = math.min(math.floor(inner_height / 2), Size.item.height_default or 40)

    local row = HorizontalGroup:new{ align = "center" }
    local icon_widget = icon(icon_names, icon_size)
    local text_width = width - 2 * (padding + border)
    if icon_widget then
        table.insert(row, icon_widget)
        table.insert(row, HorizontalSpan:new{ width = padding })
        text_width = text_width - icon_size - padding
    end

    local stack = VerticalGroup:new{ align = "left" }
    for _i, line in ipairs(lines) do
        table.insert(stack, TextWidget:new{
            text = line.text,
            face = Font:getFace(line.face or "smallinfofont"),
            bold = line.bold,
            fgcolor = line.dim and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_BLACK,
            max_width = text_width,
        })
    end
    table.insert(row, stack)

    return FrameContainer:new{
        width = width,
        height = height,
        bordersize = border,
        padding = padding,
        margin = 0,
        radius = Size.radius.window,
        color = Blitbuffer.COLOR_GRAY,
        background = Blitbuffer.COLOR_WHITE,
        -- FrameContainer sizes itself to its content, so an over-wide row would
        -- push the box past the width it was given and over its neighbour.
        -- CenterContainer with an explicit dimen reports exactly that size.
        CenterContainer:new{
            dimen = Geom:new{ w = width - 2 * (padding + border), h = inner_height },
            row,
        },
    }
end

local function mailBox(width, height)
    local unread = unreadCount()
    return box(width, height, MAIL_ICONS, {
        {
            text = unread and tostring(unread) or "–",
            face = "cfont",
            bold = unread and unread > 0,
            dim = unread == nil,
        },
    })
end

local function eventBox(width, height)
    local when, title = nextEventLabels()
    if not when then
        return box(width, height, CALENDAR_ICONS, {
            { text = _("Nothing scheduled"), dim = true },
        })
    end
    return box(width, height, CALENDAR_ICONS, {
        { text = when, bold = true },
        { text = title, face = "xx_smallinfofont", dim = true },
    })
end

local function build(ctx)
    local width = ctx and ctx.width or 400
    local height = ctx and ctx.height or 100
    local gap = Size.padding.default
    local outer = Size.padding.small
    local usable = width - 2 * outer - gap
    local mail_width = math.floor(usable * MAIL_BOX_FRACTION)
    local box_height = height - 2 * outer

    return FrameContainer:new{
        width = width,
        height = height,
        bordersize = 0,
        padding = outer,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        HorizontalGroup:new{
            align = "center",
            mailBox(mail_width, box_height),
            HorizontalSpan:new{ width = gap },
            eventBox(usable - mail_width, box_height),
        },
    }
end

--- Idempotent: ZenOS replaces the builder when an id is registered twice.
function HomeWidget.register()
    local register = rawget(_G, "__ZENOS_REGISTER_HOME_ITEM") or rawget(_G, "__ZEN_UI_REGISTER_HOME_ITEM")
    if not register then return false end
    local ok, result = pcall(register, ITEM_ID, function(ctx)
        local built, widget = pcall(build, ctx)
        if built then return widget end
        logger.warn("GoogleSuite: home widget build failed", widget)
    end, {
        label = _("Google Suite"),
        size = "s",
    })
    if not ok then
        logger.warn("GoogleSuite: home widget registration failed", result)
        return false
    end
    return result
end

return HomeWidget
