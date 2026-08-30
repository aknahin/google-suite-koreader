--[[--
The cross-section button in a title bar: Calendar from mail, Inbox from calendar.

`TitleBar` has exactly two icon slots, and `close_callback` claims the right one
(titlebar.lua sets `right_icon = "close"` from it), so a third button has to be
placed by hand. A TitleBar is an `OverlapGroup`, which positions any child
carrying an `overlap_offset`, so the button is measured against the close button
already in there and inserted just to its left.

Two details decide whether the taps land:

* The close button is built with `padding_left = 2 * icon_size` to widen its tap
  zone leftwards, which swallows the space this button wants. `WidgetContainer`
  propagates events to children in array order and stops at the first that
  consumes, so this one is inserted *before* the close button and gets first
  refusal — and returns false outside its own box, leaving close intact.
* `InputContainer:paintTo` writes the paint position back into `self.dimen`, and
  the gesture range is that same table, so the zone follows the button wherever
  the overlap group puts it.

All of it reads KOReader-internal structure, so the whole attach is wrapped: if
a future release reshapes TitleBar the button simply does not appear, and the
title bar's menu still offers the same jump.
--]]

local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local CenterContainer = require("ui/widget/container/centercontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local logger = require("logger")

local Icons = require("lib/icons")

local SectionButton = {}

--- Where the close button sits in the overlap group's child list.
local function indexOf(group, child)
    for index = #group, 1, -1 do
        if rawequal(group[index], child) then return index end
    end
end

local function build(icon_name, size, box, callback)
    local icon = Icons.get(icon_name, size)
    if not icon then return nil end

    local button = InputContainer:new{
        dimen = Geom:new{ w = box, h = box },
    }
    button.ges_events = {
        TapSectionButton = {
            GestureRange:new{ ges = "tap", range = button.dimen },
        },
    }
    button.onTapSectionButton = function(self, _arg, ges)
        if not (self.dimen and ges and ges.pos and self.dimen:contains(ges.pos)) then
            return false
        end
        callback()
        return true
    end
    button[1] = CenterContainer:new{
        dimen = Geom:new{ w = box, h = box },
        icon,
    }
    return button
end

--[[--
Adds `icon_name` to `title_bar`, immediately left of its close button.

@tparam table title_bar a KOReader TitleBar that was given a close_callback
@tparam string icon_name a name under this plugin's icons/ directory
@tparam function callback run on tap
@treturn boolean whether the button was attached
--]]
function SectionButton.attach(title_bar, icon_name, callback)
    local ok, err = pcall(function()
        local close = title_bar.right_button
        local close_index = close and indexOf(title_bar, close)
        assert(close and close_index and close.image and close.dimen,
               "title bar has no close button to sit beside")

        local icon_size = close.image:getSize().w
        local padding = Size.padding.default
        local box = icon_size + 2 * padding
        local gap = Size.padding.large

        -- The close button is right-aligned, so its icon starts that far in
        -- from the title bar's right edge.
        local bar_width = title_bar.width or (title_bar.dimen and title_bar.dimen.w)
        assert(bar_width, "title bar has no width to measure against")
        local close_icon_left = bar_width - close.dimen.w + (close.padding_left or 0)
        local x = close_icon_left - gap - icon_size - padding
        local y = (close.padding_top or 0) - padding
        if x < 0 then x = 0 end
        if y < 0 then y = 0 end

        local button = build(icon_name, icon_size, box, callback)
        assert(button, "icon unavailable")
        button.overlap_offset = { x, y }
        table.insert(title_bar, close_index, button)
    end)
    if not ok then
        logger.warn("GoogleSuite: section button not attached", err)
    end
    return ok
end

return SectionButton
