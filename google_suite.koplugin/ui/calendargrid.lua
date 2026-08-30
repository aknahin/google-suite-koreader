--[[--
Month and week grids.

Both views are the same primitive — rows of seven day cells — so one widget
covers them, with `mode` deciding how many rows and how many event lines each
cell can hold. Modelled on `plugins/statistics.koplugin/calendarview.lua`
(`CalendarDay`/`CalendarWeek`), KOReader's in-tree precedent for a month grid,
with two deliberate departures:

* Taps are resolved from coordinates against the grid geometry rather than by
  giving all 42 cells their own InputContainer. Fewer widgets to build and free
  on every repaint, which matters on an e-ink page turn.
* It handles rotation. `calendarview.lua` does not; this follows
  `Menu:onScreenResize` and re-runs `init()`.

All date arithmetic comes from `lib/gcal.lua`'s civil-date helpers, never from
`os.time`, so the layout cannot drift with the timezone or a DST boundary.
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
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")

local Fmt = require("lib/fmt")
local Gcal = require("lib/gcal")

local Input = Device.input
local Screen = Device.screen

local WEEKDAY_NAMES = { _("Sun"), _("Mon"), _("Tue"), _("Wed"), _("Thu"), _("Fri"), _("Sat") }

local CalendarGrid = InputContainer:extend{
    mode = "month",          -- "month" or "week"
    anchor = nil,            -- any day key inside the period being shown
    events_by_day = nil,     -- Gcal.bucketByDay output
    start_dow = 2,           -- 1 = Sunday .. 7 = Saturday
    title = "",
    on_day_tap = nil,        -- function(day_key)
    on_navigate = nil,       -- function(step) with step -1 or 1
    on_menu = nil,
    close_callback = nil,
}

--- The day cells of the current period, in reading order.
function CalendarGrid:cells()
    if self.mode == "week" then
        return Gcal.weekDays(self.anchor, self.start_dow)
    end
    local year, month = self.anchor:match("^(%d%d%d%d)%-(%d%d)")
    return Gcal.monthDays(tonumber(year), tonumber(month), self.start_dow)
end

function CalendarGrid:init()
    self.dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() }
    self.covers_fullscreen = true

    if Device:hasKeys() then
        self.key_events.Close = { { Input.group.Back } }
        self.key_events.NextPeriod = { { Input.group.PgFwd } }
        self.key_events.PrevPeriod = { { Input.group.PgBack } }
    end
    if Device:isTouchDevice() then
        self.ges_events.Tap = { GestureRange:new{ ges = "tap", range = self.dimen } }
        self.ges_events.Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } }
    end

    -- Size.line.thin is scaleBySize(0.5), which can round to 0 on a low-DPI
    -- Kindle and leave the grid with no visible separation at all.
    self.rule = math.max(Size.line.medium or 1, 1)
    self.cell_padding = Size.padding.small
    self.outer_padding = Size.padding.large
    self.day_width = math.floor((self.dimen.w - 2 * self.outer_padding - 6 * self.rule) / 7)
    -- Push the pixels lost to rounding back into the outer margin.
    self.outer_padding = math.floor((self.dimen.w - 7 * self.day_width - 6 * self.rule) / 2)
    self.grid_width = 7 * self.day_width + 6 * self.rule
    self.col_stride = self.day_width + self.rule

    self.title_bar = TitleBar:new{
        fullscreen = true,
        width = self.dimen.w,
        align = "left",
        title = self.title,
        title_h_padding = self.outer_padding,
        left_icon = "appbar.menu",
        left_icon_tap_callback = function()
            if self.on_menu then self.on_menu() end
        end,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }

    local day_names = self:buildDayNames()
    local cells = self:cells()
    self.rows = #cells / 7
    self.grid_top = self.title_bar:getHeight() + day_names:getSize().h + self.rule
    local available = self.dimen.h - self.grid_top - self.outer_padding
    self.row_height = math.floor((available - (self.rows - 1) * self.rule) / self.rows)
    self.row_stride = self.row_height + self.rule

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
            day_names,
            self:hairline(self.dimen.w),
            self:buildRows(cells),
        },
    }
end

--- A hairline. Separation on e-ink comes from rules and whitespace; filled
--- boxes around every cell read as 42 crowded cards.
function CalendarGrid:hairline(width, height)
    return LineWidget:new{
        dimen = Geom:new{ w = width, h = height or self.rule },
        background = Blitbuffer.COLOR_GRAY,
    }
end

function CalendarGrid:buildDayNames()
    local group = HorizontalGroup:new{ HorizontalSpan:new{ width = self.outer_padding } }
    local face = Font:getFace("xx_smallinfofont")
    for index = 0, 6 do
        local label = TextWidget:new{
            text = WEEKDAY_NAMES[(self.start_dow - 1 + index) % 7 + 1],
            face = face,
            bold = true,
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }
        table.insert(group, CenterContainer:new{
            dimen = Geom:new{ w = self.day_width, h = label:getSize().h * 2 },
            label,
        })
        if index < 6 then
            table.insert(group, HorizontalSpan:new{ width = self.rule })
        end
    end
    return group
end

function CalendarGrid:buildRows(cells)
    local today = os.date("%Y-%m-%d")
    local face = Font:getFace("xx_smallinfofont")

    -- Measure once; every cell uses the same metrics.
    local probe = TextWidget:new{ text = " 30 ", face = face, bold = true }
    local day_number_height = probe:getSize().h
    probe:free()
    probe = TextWidget:new{ text = "09:30 Standup", face = face }
    local line_height = probe:getSize().h
    probe:free()

    self.lines_per_cell = self:linesPerCell(day_number_height, line_height)
    local style = {
        today = today,
        face = face,
        text_width = self.day_width - 2 * self.cell_padding,
    }

    local grid = VerticalGroup:new{ align = "left" }
    for row = 1, self.rows do
        local row_group = HorizontalGroup:new{
            align = "top",
            HorizontalSpan:new{ width = self.outer_padding },
        }
        for column = 1, 7 do
            table.insert(row_group, self:buildCell(cells[(row - 1) * 7 + column], style))
            if column < 7 then
                table.insert(row_group, self:hairline(self.rule, self.row_height))
            end
        end
        table.insert(grid, row_group)
        if row < self.rows then
            table.insert(grid, HorizontalGroup:new{
                HorizontalSpan:new{ width = self.outer_padding },
                self:hairline(self.grid_width),
            })
        end
    end
    return grid
end

--- How many event lines fit in a cell, after the day number.
function CalendarGrid:linesPerCell(day_number_height, line_height)
    local inner = self.row_height - 2 * self.cell_padding - day_number_height
    return math.max(0, math.floor(inner / line_height))
end

--- The day number, inverted into a solid chip when it is today. With no colour
--- available, inversion is the only marker that survives a greyscale refresh.
function CalendarGrid:buildDayNumber(cell, style, is_today)
    local label = TextWidget:new{
        text = " " .. cell.day .. " ",
        face = style.face,
        bold = is_today,
        fgcolor = is_today and Blitbuffer.COLOR_WHITE
            or (cell.outside and Blitbuffer.COLOR_GRAY or Blitbuffer.COLOR_BLACK),
    }
    if not is_today then return label end
    return FrameContainer:new{
        bordersize = 0,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_BLACK,
        label,
    }
end

function CalendarGrid:buildCell(cell, style)
    local is_today = cell.key == style.today
    local inner = VerticalGroup:new{ align = "left" }
    table.insert(inner, self:buildDayNumber(cell, style, is_today))

    local events = (self.events_by_day or {})[cell.key] or {}
    local budget = self.lines_per_cell
    local shown = math.min(#events, budget)
    -- Spend a line on the overflow marker only when it still shows more events
    -- than it hides.
    if #events > budget and budget > 1 then shown = budget - 1 end

    for index = 1, shown do
        local event = events[index]
        local label = event.all_day and Fmt.clip(event.title, 40)
            or (Fmt.clock(event.start_epoch) .. " " .. Fmt.clip(event.title, 40))
        table.insert(inner, TextWidget:new{
            text = label,
            face = style.face,
            bold = event.all_day,
            max_width = style.text_width,
        })
    end
    if #events > shown then
        table.insert(inner, TextWidget:new{
            text = "+" .. (#events - shown),
            face = style.face,
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            max_width = style.text_width,
        })
    end

    -- OverlapGroup with an explicit dimen reports exactly that size regardless
    -- of its content (overlapgroup.lua:41). FrameContainer does NOT: its
    -- getSize() is content-derived and width/height only affect the frame it
    -- paints, so cells built that way sized themselves to their text, went
    -- ragged, and painted over each other.
    return OverlapGroup:new{
        dimen = Geom:new{ w = self.day_width, h = self.row_height },
        allow_mirroring = false,
        VerticalGroup:new{
            align = "left",
            VerticalSpan:new{ width = self.cell_padding },
            HorizontalGroup:new{
                HorizontalSpan:new{ width = self.cell_padding },
                inner,
            },
        },
    }
end

--- Which day cell a screen position falls in, or nil if it missed the grid.
function CalendarGrid:cellAt(x, y)
    if y < self.grid_top then return nil end
    local row = math.floor((y - self.grid_top) / self.row_stride) + 1
    local column = math.floor((x - self.outer_padding) / self.col_stride) + 1
    if row < 1 or row > self.rows or column < 1 or column > 7 then return nil end
    return self:cells()[(row - 1) * 7 + column]
end

function CalendarGrid:onTap(_arg, ges)
    local cell = ges and ges.pos and self:cellAt(ges.pos.x, ges.pos.y)
    if cell and self.on_day_tap then self.on_day_tap(cell.key) end
    return true
end

function CalendarGrid:onSwipe(_arg, ges)
    if ges.direction == "west" then
        return self:onNextPeriod()
    elseif ges.direction == "east" then
        return self:onPrevPeriod()
    end
    return true
end

function CalendarGrid:onNextPeriod()
    if self.on_navigate then self.on_navigate(1) end
    return true
end

function CalendarGrid:onPrevPeriod()
    if self.on_navigate then self.on_navigate(-1) end
    return true
end

--- Rotation and resize: rebuild at the new dimensions rather than fight it.
function CalendarGrid:onScreenResize()
    self:init()
    UIManager:setDirty(self, "full")
    return false
end

function CalendarGrid:onSetRotationMode(mode)
    if mode ~= nil and mode ~= Screen:getRotationMode() then
        Screen:setRotationMode(mode)
        self:init()
        UIManager:setDirty(self, "full")
        return true
    end
end

function CalendarGrid:onClose()
    UIManager:close(self)
    if self.close_callback then self.close_callback() end
    return true
end

return CalendarGrid
