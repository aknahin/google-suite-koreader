--[[--
The ZenOS Home page widget: two boxes, unread mail and the next event.

    ┌──────────┐ ┌────────────────────────────────────┐
    │  ✉   4   │ │  📅  5:20 PM  Design review        │
    └──────────┘ └────────────────────────────────────┘

Each box opens what it is showing: the left one the unread mail, the right one
the agenda.

Reads only from the cache — the Home page is drawn on every wake, and it must
never wait on the radio, so the unread count is derived from the last synced
inbox rather than from a Gmail label lookup, and the next event from the agenda
`ui/agenda.lua` writes after every fetch. Registration is guarded because ZenOS
may load before or after this plugin; `main.lua` also calls this from the
`ZenOSReady` handler.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local logger = require("logger")
local _ = require("gettext")

local Cache = require("lib/cache")
local Fmt = require("lib/fmt")
local Gcal = require("lib/gcal")
local Icons = require("lib/icons")

local Screen = Device.screen

local HomeWidget = {}

local ITEM_ID = "google_suite.summary"

--- The unread box is sized to its content; whatever is left goes to the event
--- box, which is the one with something to say.
local MAIL_BOX_FRACTION = 0.28

-- ------------------------------------------------------------------- data ---

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
    if event.day_key ~= os.date("%Y-%m-%d") then
        when = Fmt.dayHeading(event.day_key) .. " " .. when
    end
    return when, event.title
end

-- ----------------------------------------------------------------- layout ---

--[[--
Wraps a box so tapping it opens the section it summarises.

The gesture range is the whole screen and the hit test is done against the box's
own `dimen`, which `InputContainer:paintTo` fills in with wherever the Home page
ended up putting us — the range cannot be computed up front, because the widget
is built before it is placed. This is the contract ZenOS's built-in Home
components use, including deferring to `ctx.openTopMenu` and `ctx.editMode` so
the Home page keeps its own long-press menu and widget-arranging mode.
--]]
local function tappable(frame, width, height, ctx, on_tap)
    local container = InputContainer:new{
        dimen = Geom:new{ w = width, h = height },
    }
    container.ges_events = {
        TapGoogleSuiteBox = {
            GestureRange:new{ ges = "tap", range = Geom:new{
                x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight(),
            } },
        },
    }
    container.onTapGoogleSuiteBox = function(self, _arg, ges)
        if not (self.dimen and ges and ges.pos and self.dimen:contains(ges.pos)) then
            return false
        end
        if ctx and ctx.openTopMenu and ctx.openTopMenu(ges) then return true end
        -- While the Home page is being rearranged, a tap belongs to the drag.
        if ctx and ctx.editMode then return false end
        on_tap()
        return true
    end
    container[1] = frame
    return container
end

--- One box: icon on the left, a stack of lines on the right.
local function box(opts)
    local width, height = opts.width, opts.height
    local padding = Size.padding.default
    local border = Size.border.thin
    local inner_height = height - 2 * (padding + border)
    local icon_size = math.min(math.floor(inner_height / 2), Size.item.height_default or 40)

    local row = HorizontalGroup:new{ align = "center" }
    local icon = Icons.get(opts.icon, icon_size)
    local text_width = width - 2 * (padding + border)
    if icon then
        table.insert(row, icon)
        table.insert(row, HorizontalSpan:new{ width = padding })
        text_width = text_width - icon_size - padding
    end

    local stack = VerticalGroup:new{ align = "left" }
    for _i, line in ipairs(opts.lines) do
        table.insert(stack, TextWidget:new{
            text = line.text,
            face = Font:getFace(line.face or "smallinfofont"),
            bold = line.bold,
            fgcolor = line.dim and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_BLACK,
            max_width = text_width,
        })
    end
    table.insert(row, stack)

    local frame = FrameContainer:new{
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
    return tappable(frame, width, height, opts.ctx, opts.on_tap)
end

--- Opening the plugin is deferred to tap time so the Home page never pulls the
--- whole app in just to draw a summary.
local function open(section, target)
    require("ui/appview").openSection(section, target)
end

local function mailBox(width, height, ctx)
    local unread = unreadCount()
    return box{
        width = width, height = height, ctx = ctx, icon = "mail",
        on_tap = function() open("mail", "unread") end,
        lines = { {
            text = unread and tostring(unread) or "–",
            face = "cfont",
            bold = unread and unread > 0,
            dim  = unread == nil,
        } },
    }
end

local function eventBox(width, height, ctx)
    local when, title = nextEventLabels()
    local lines = when
        and { { text = when, bold = true },
              { text = title, face = "xx_smallinfofont", dim = true } }
        or { { text = _("Nothing scheduled"), dim = true } }
    return box{
        width = width, height = height, ctx = ctx, icon = "calendar",
        -- The agenda, not a grid: it is the view covering the days this box
        -- draws from.
        on_tap = function() open("calendar", "list") end,
        lines = lines,
    }
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
            mailBox(mail_width, box_height, ctx),
            HorizontalSpan:new{ width = gap },
            eventBox(usable - mail_width, box_height, ctx),
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
