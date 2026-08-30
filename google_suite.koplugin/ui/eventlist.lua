--[[--
A paged list of event cards.

Both places that show events as a vertical list — the agenda and the popup
behind a grid day cell — draw them here, so an event looks the same wherever it
is read. Each card carries its start time, a rule, its end time, the title, and
whatever note the event has.

Paged rather than pixel-scrolled. `ScrollableContainer` would mean a partial
redraw on every pan, which on e-ink is either ghosting or a full flash per
frame; a page turn is one refresh for a screenful. It also lets taps be resolved
from the laid-out card geometry, the same trick `ui/calendargrid.lua` uses to
avoid giving every row its own `InputContainer`.
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
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local util = require("util")
local T = require("ffi/util").template
local _ = require("gettext")

local Fmt = require("lib/fmt")
local Navbar = require("ui/navbar")
local SectionButton = require("ui/sectionbutton")

local Input = Device.input
local Screen = Device.screen

local EventList = InputContainer:extend{
    title = "",
    subtitle = nil,          -- e.g. a "cached" marker; joined with the page label
    events = nil,            -- flat list of normalized events, already sorted
    day_headings = true,     -- false for a single-day list, where they are noise
    empty_text = nil,
    on_menu = nil,           -- function(); omitted hides the title bar's left icon
    on_event_tap = nil,      -- function(event)
    on_section_switch = nil, -- function(); adds the Inbox button beside close
    on_zen_navigate = nil,   -- function(tab_id); omitted hides the ZenOS navbar
    close_callback = nil,
}

--- How many lines of a wrapped block are worth the vertical space on a card.
local TITLE_LINES = 2
local NOTE_LINES = 2

function EventList:init()
    self.dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() }
    self.covers_fullscreen = true
    self.page = self.page or 1

    if Device:hasKeys() then
        self.key_events.Close = { { Input.group.Back } }
        self.key_events.NextPage = { { Input.group.PgFwd } }
        self.key_events.PrevPage = { { Input.group.PgBack } }
    end
    if Device:isTouchDevice() then
        self.ges_events.Tap = { GestureRange:new{ ges = "tap", range = self.dimen } }
        self.ges_events.Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } }
    end

    self.outer_padding = Size.padding.large
    self.card_gap = Size.padding.small
    self.content_width = self.dimen.w - 2 * self.outer_padding

    -- Size.line.thin is scaleBySize(0.5), which can round to 0 on a low-DPI
    -- Kindle and leave the page bar with no rule above it at all.
    self.rule = math.max(Size.line.medium or 1, 1)

    -- Our own copy of the ZenOS bar, drawn inside the page because a tap can
    -- never reach the real one underneath. See ui/navbar.lua.
    self.zen_navbar, self.zen_navbar_height = nil, 0
    if self.on_zen_navigate then
        self.zen_navbar, self.zen_navbar_height =
            Navbar.build(self.dimen.w, self.on_zen_navigate)
        self.zen_navbar_height = self.zen_navbar_height or 0
    end

    local blocks = self:buildBlocks()
    -- Chicken and egg: the page bar's height comes off the space the cards get,
    -- and how many pages there are decides whether there is a page bar at all.
    -- The bar is a fixed height whether it says "1 of 1" or "3 of 9", so it is
    -- measured first and that height reserved unconditionally. Laying out
    -- against a bar that might vanish is what would make a page overflow.
    self:measurePageBar()
    self:layoutTitleBar(" ")
    self.pages = self:paginate(blocks)
    if self.page > #self.pages then self.page = #self.pages end
    if self.page < 1 then self.page = 1 end
    self:layoutTitleBar(self:subtitleText())

    self[1] = FrameContainer:new{
        width = self.dimen.w,
        height = self.dimen.h,
        padding = 0,
        margin = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "left",
            self.title_bar,
            self:buildPage(),
            self:buildPageBar(),
            self.zen_navbar,
        },
    }
end

--- Always a non-empty string. The title bar reserves a subtitle line only when
--- it has one, and pagination is measured against the bar's height, so letting
--- it come and go would make the first page overflow by exactly that line. The
--- page count lives in the footer, not here.
function EventList:subtitleText()
    if self.subtitle and self.subtitle ~= "" then return self.subtitle end
    return " "
end

function EventList:layoutTitleBar(subtitle)
    self.title_bar = TitleBar:new{
        fullscreen = true,
        width = self.dimen.w,
        align = "left",
        title = self.title,
        subtitle = subtitle,
        title_h_padding = self.outer_padding,
        left_icon = self.on_menu and "appbar.menu" or nil,
        left_icon_tap_callback = function()
            if self.on_menu then self.on_menu() end
        end,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }
    if self.on_section_switch then
        SectionButton.attach(self.title_bar, "mail", self.on_section_switch)
    end
    self.content_top = self.title_bar:getHeight()
    self.content_height = self.dimen.h - self.content_top - self.outer_padding
        - (self.page_bar_height or 0) - (self.zen_navbar_height or 0)
end

-- ------------------------------------------------------------------ blocks ---

--[[--
Every day heading and card, measured, in reading order.

Widgets are built once here and reused by whichever page they land on;
rebuilding them per page turn would re-shape every text run again.

@treturn table list of { widget, height, event }
--]]
function EventList:buildBlocks()
    local blocks = {}
    local events = self.events or {}

    if #events == 0 then
        local label = TextWidget:new{
            text = self.empty_text or _("Nothing scheduled."),
            face = Font:getFace("cfont"),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            max_width = self.content_width,
        }
        blocks[1] = { widget = label, height = label:getSize().h }
        return blocks
    end

    local current_day
    for _i, event in ipairs(events) do
        if self.day_headings and event.day_key ~= current_day then
            current_day = event.day_key
            local heading = self:buildHeading(event.day_key)
            blocks[#blocks + 1] = {
                widget = heading, height = heading:getSize().h, heading = true,
            }
        end
        local card = self:buildCard(event)
        blocks[#blocks + 1] = { widget = card, height = card:getSize().h, event = event }
    end
    return blocks
end

function EventList:buildHeading(day_key)
    local label = TextWidget:new{
        text = Fmt.dayHeading(day_key),
        face = Font:getFace("cfont"),
        bold = true,
        max_width = self.content_width,
    }
    return VerticalGroup:new{
        align = "left",
        VerticalSpan:new{ width = Size.padding.default },
        label,
        VerticalSpan:new{ width = Size.padding.small },
    }
end

--- The note under the title: where it is, then what it says.
local function noteText(event)
    local parts = {}
    if event.location and event.location ~= "" then
        parts[#parts + 1] = event.location
    end
    if event.description and event.description ~= "" then
        local plain = util.htmlToPlainTextIfHtml(event.description)
        plain = (plain or ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
        if plain ~= "" then parts[#parts + 1] = plain end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, " · ")
end

--[[--
One event card.

  ┌──────────────────────┐
  │ 5:20 PM              │
  │ ────                 │
  │ 6:35 PM              │
  │ Design review        │
  │ Conf room B · …      │
  └──────────────────────┘

The border is what separates one event from the next; on a greyscale panel a
frame reads faster than the whitespace a plain list would rely on.
--]]
function EventList:buildCard(event)
    local border = Size.border.thin
    local padding = Size.padding.default
    local inner_width = self.content_width - 2 * (border + padding)

    local inner = VerticalGroup:new{ align = "left" }

    if event.all_day then
        table.insert(inner, TextWidget:new{
            text = _("All day"),
            face = Font:getFace("smallinfofont"),
            bold = true,
            max_width = inner_width,
        })
    else
        table.insert(inner, TextWidget:new{
            text = Fmt.clock12(event.start_epoch),
            face = Font:getFace("smallinfofont"),
            bold = true,
            max_width = inner_width,
        })
        table.insert(inner, VerticalSpan:new{ width = Size.padding.small })
        table.insert(inner, LineWidget:new{
            -- Short on purpose: it joins the two times rather than dividing the
            -- card, which a full-width rule would read as.
            dimen = Geom:new{ w = math.floor(inner_width / 6),
                              h = math.max(Size.line.medium or 1, 1) },
            background = Blitbuffer.COLOR_GRAY,
        })
        table.insert(inner, VerticalSpan:new{ width = Size.padding.small })
        table.insert(inner, TextWidget:new{
            text = Fmt.clock12(event.end_epoch),
            face = Font:getFace("smallinfofont"),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            max_width = inner_width,
        })
    end

    table.insert(inner, VerticalSpan:new{ width = Size.padding.default })
    table.insert(inner, self:buildWrapped(event.title, inner_width,
        Font:getFace("cfont"), true, Blitbuffer.COLOR_BLACK, TITLE_LINES))

    local note = noteText(event)
    if note then
        table.insert(inner, VerticalSpan:new{ width = Size.padding.small })
        table.insert(inner, self:buildWrapped(note, inner_width,
            Font:getFace("xx_smallinfofont"), false, Blitbuffer.COLOR_DARK_GRAY, NOTE_LINES))
    end

    return FrameContainer:new{
        width = self.content_width,
        bordersize = border,
        padding = padding,
        margin = 0,
        radius = Size.radius.window,
        color = Blitbuffer.COLOR_GRAY,
        background = Blitbuffer.COLOR_WHITE,
        inner,
    }
end

--- Text wrapped to `width` and cropped to `max_lines`, with an ellipsis when it
--- overflows. Measured first so the card's height is exact rather than reserved.
function EventList:buildWrapped(text, width, face, bold, fgcolor, max_lines)
    local box = TextBoxWidget:new{
        text = text or "",
        face = face,
        bold = bold,
        fgcolor = fgcolor,
        width = width,
    }
    -- TextBoxWidget lays its lines out in init(), so the wrapped line count is
    -- known here; dividing the measured height by it gives the true line pitch,
    -- leading included, without assuming the widget's internal metrics.
    local lines = box.vertical_string_list and #box.vertical_string_list or 1
    if lines < 1 then lines = 1 end
    if lines <= max_lines then return box end
    local line_height = math.floor(box:getSize().h / lines)
    box:free()
    return TextBoxWidget:new{
        text = text or "",
        face = face,
        bold = bold,
        fgcolor = fgcolor,
        width = width,
        height = line_height * max_lines,
        height_adjust = true,
        height_overflow_show_ellipsis = true,
    }
end

-- -------------------------------------------------------------- pagination ---

--- Packs blocks into pages. A day heading is never left stranded at the foot of
--- a page with its first event overleaf: when the event will not fit, the
--- heading is carried over with it.
function EventList:paginate(blocks)
    local pages = {}
    local page = {}
    local used = 0

    for _i, block in ipairs(blocks) do
        local needed = block.height + (#page > 0 and self.card_gap or 0)
        if #page > 0 and used + needed > self.content_height then
            local carried
            if page[#page].heading then carried = table.remove(page) end
            -- Carrying the only block off a page leaves nothing to publish.
            if #page > 0 then pages[#pages + 1] = page end
            page, used = {}, 0
            if carried then
                page[1] = carried
                used = carried.height
                needed = block.height + self.card_gap
            else
                needed = block.height
            end
        end
        page[#page + 1] = block
        used = used + needed
    end
    if #page > 0 then pages[#pages + 1] = page end
    if #pages == 0 then pages[1] = {} end
    return pages
end

--- Lays the current page out and records each card's vertical extent, which is
--- what `onTap` resolves against.
function EventList:buildPage()
    local group = VerticalGroup:new{ align = "left" }
    self.hit_zones = {}
    local y = self.content_top

    for index, block in ipairs(self.pages[self.page] or {}) do
        if index > 1 then
            table.insert(group, VerticalSpan:new{ width = self.card_gap })
            y = y + self.card_gap
        end
        table.insert(group, HorizontalGroup:new{
            HorizontalSpan:new{ width = self.outer_padding },
            block.widget,
        })
        if block.event then
            self.hit_zones[#self.hit_zones + 1] = {
                top = y, bottom = y + block.height, event = block.event,
            }
        end
        y = y + block.height
    end

    -- Push the page bar down to the foot rather than letting it ride up under
    -- the last card on a short page.
    local slack = self.content_top + self.content_height - y
    if slack > 0 then
        table.insert(group, VerticalSpan:new{ width = slack })
        y = y + slack
    end
    self.page_bar_top = y
    return group
end

function EventList:goToPage(page)
    if page < 1 or page > #self.pages or page == self.page then return end
    self.page = page
    self:init()
    -- A page turn replaces the whole screen; a partial refresh would leave the
    -- previous page's cards ghosting under this one.
    UIManager:setDirty(self, "full")
end

-- --------------------------------------------------------------- page bar ---

--[[--
The page bar's height, which is the same whatever it ends up saying.

Measured before anything is laid out because the cards are given whatever is
left over; deciding afterwards would mean paginating against a height the page
does not actually have.
--]]
function EventList:measurePageBar()
    local probe = TextWidget:new{ text = "0 / 0", face = Font:getFace("smallinfofont") }
    local text_height = probe:getSize().h
    probe:free()
    self.page_bar_icon = math.floor(text_height * 1.2)
    self.page_bar_height = math.max(text_height, self.page_bar_icon)
        + 2 * Size.padding.default + self.rule
end

--- A chevron, or an equally wide blank when there is nowhere to go that way.
function EventList:pageChevron(icon_name, enabled)
    local size = self.page_bar_icon
    if not enabled then
        return HorizontalSpan:new{ width = size }
    end
    local ok, icon = pcall(IconWidget.new, IconWidget, {
        icon = icon_name, width = size, height = size, alpha = true,
    })
    if ok and icon then return icon end
    return HorizontalSpan:new{ width = size }
end

--[[--
The footer: ‹ 2 of 5 ›, with a rule above it.

Taps are resolved in `onTap` against `page_bar_top` and the thirds below,
matching how the cards are hit-tested — the whole widget already owns one tap
handler, so the chevrons do not need containers of their own.
--]]
function EventList:buildPageBar()
    local total = #self.pages
    local third = math.floor(self.dimen.w / 3)
    local row_height = self.page_bar_height - self.rule

    local label = TextWidget:new{
        text = T(_("%1 of %2"), self.page, total),
        face = Font:getFace("smallinfofont"),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        max_width = third,
    }

    local function cell(widget, width)
        return CenterContainer:new{
            dimen = Geom:new{ w = width, h = row_height },
            widget,
        }
    end

    return VerticalGroup:new{
        align = "left",
        LineWidget:new{
            dimen = Geom:new{ w = self.dimen.w, h = self.rule },
            background = Blitbuffer.COLOR_GRAY,
        },
        HorizontalGroup:new{
            align = "center",
            cell(self:pageChevron("chevron.left", self.page > 1), third),
            cell(label, self.dimen.w - 2 * third),
            cell(self:pageChevron("chevron.right", self.page < total), third),
        },
    }
end

-- ------------------------------------------------------------------ events ---

function EventList:onTap(_arg, ges)
    local pos = ges and ges.pos
    if not pos then return true end

    local page_bar_bottom = self.dimen.h - (self.zen_navbar_height or 0)
    if self.page_bar_top and pos.y >= self.page_bar_top
            and pos.y < page_bar_bottom then
        local third = math.floor(self.dimen.w / 3)
        if pos.x < third then
            return self:onPrevPage()
        elseif pos.x >= self.dimen.w - third then
            return self:onNextPage()
        end
        return true
    end

    for _i, zone in ipairs(self.hit_zones or {}) do
        if pos.y >= zone.top and pos.y <= zone.bottom then
            if self.on_event_tap then self.on_event_tap(zone.event) end
            return true
        end
    end
    return true
end

function EventList:onSwipe(_arg, ges)
    if ges.direction == "west" then
        return self:onNextPage()
    elseif ges.direction == "east" then
        return self:onPrevPage()
    end
    return true
end

function EventList:onNextPage()
    self:goToPage(self.page + 1)
    return true
end

function EventList:onPrevPage()
    self:goToPage(self.page - 1)
    return true
end

--- Rotation and resize: rebuild at the new dimensions rather than fight it.
function EventList:onScreenResize()
    self:init()
    UIManager:setDirty(self, "full")
    return false
end

function EventList:onSetRotationMode(mode)
    if mode ~= nil and mode ~= Screen:getRotationMode() then
        Screen:setRotationMode(mode)
        self:init()
        UIManager:setDirty(self, "full")
        return true
    end
end

--- Swaps the contents in place, for a cache-then-refresh repaint. The current
--- page is kept rather than reset: the refresh usually lands while the user is
--- already reading, and init() clamps it if the list got shorter.
function EventList:setEvents(events, title)
    self.events = events
    if title then self.title = title end
    self:init()
    UIManager:setDirty(self, "full")
end

function EventList:onClose()
    UIManager:close(self)
    if self.close_callback then self.close_callback() end
    return true
end

return EventList
