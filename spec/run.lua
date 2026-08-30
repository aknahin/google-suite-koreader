-- Runs the plugin's pure logic against the stub harness in spec/harness.lua.
--   luajit spec/run.lua
require("spec.harness")

local passed, failed = 0, 0

local function check(name, ok, detail)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL  " .. name .. (detail and ("  -> " .. tostring(detail)) or ""))
    end
end

local function equal(name, actual, expected)
    check(name, actual == expected, string.format("got %s, expected %s",
        tostring(actual), tostring(expected)))
end

-- Every module must at least load cleanly.
for _i, name in ipairs({
    "lib/const", "lib/http", "lib/account", "lib/cache", "lib/fmt",
    "lib/mimeutil", "lib/batch", "lib/gmail", "lib/gcal", "lib/icons",
    "lib/zenos", "lib/compose",
    "ui/task", "ui/setup", "ui/sectionbutton", "ui/navbar", "ui/compose", "ui/mailview",
    "ui/maillist", "ui/agenda", "ui/calendargrid", "ui/eventlist",
    "ui/homewidget", "ui/appview", "main",
}) do
    local ok, err = pcall(require, name)
    check("loads " .. name, ok, err)
end

local MimeUtil = require("lib/mimeutil")
local Gcal = require("lib/gcal")
local Batch = require("lib/batch")
local Gmail = require("lib/gmail")
local Http = require("lib/http")
local Fmt = require("lib/fmt")

-- base64url: Gmail omits padding and swaps two characters of the alphabet.
equal("base64url plain", MimeUtil.decodeBase64Url("SGVsbG8sIHdvcmxkIQ"), "Hello, world!")
equal("base64url is padding tolerant", MimeUtil.decodeBase64Url("SGVsbG8="), "Hello")
equal("base64url handles - and _", MimeUtil.decodeBase64Url("_-8"), string.char(0xFF, 0xEF))
equal("base64url on empty input", MimeUtil.decodeBase64Url(""), "")

-- RFC 2047 encoded-words.
equal("encoded-word B/UTF-8", MimeUtil.decodeHeader("=?UTF-8?B?Q2Fmw6k=?="), "Café")
equal("encoded-word Q/UTF-8", MimeUtil.decodeHeader("=?UTF-8?Q?Caf=C3=A9?="), "Café")
equal("encoded-word Q underscore is space", MimeUtil.decodeHeader("=?UTF-8?Q?a_b?="), "a b")
equal("encoded-word latin-1 widens", MimeUtil.decodeHeader("=?ISO-8859-1?Q?Caf=E9?="), "Café")
equal("adjacent encoded-words join",
      MimeUtil.decodeHeader("=?UTF-8?B?Q2Fm?= =?UTF-8?B?w6k=?="), "Café")
equal("plain header untouched", MimeUtil.decodeHeader("Weekly report"), "Weekly report")

local name, address = MimeUtil.parseAddress('"Ada Lovelace" <ada@example.com>')
equal("address display name", name, "Ada Lovelace")
equal("address mailbox", address, "ada@example.com")
local bare_name, bare_address = MimeUtil.parseAddress("ada@example.com")
equal("bare address name falls back", bare_name, "ada@example.com")
equal("bare address mailbox", bare_address, "ada@example.com")
local encoded_name = MimeUtil.parseAddress("=?UTF-8?B?QcOfbGVy?= <a@b.c>")
equal("address name is decoded", encoded_name, "Aßler")

equal("header lookup is case-insensitive",
      MimeUtil.header({ { name = "Subject", value = "Hi" } }, "subject"), "Hi")

-- RFC 3339 parsing must not depend on the device's timezone.
equal("timegm epoch zero", Gcal.timegm(1970, 1, 1, 0, 0, 0), 0)
equal("timegm leap day", Gcal.timegm(2024, 2, 29, 12, 0, 0), 1709208000)
equal("rfc3339 Z", Gcal.parseRfc3339("2026-08-30T12:00:00Z"), 1788091200)
equal("rfc3339 positive offset", Gcal.parseRfc3339("2026-08-30T18:00:00+06:00"), 1788091200)
equal("rfc3339 negative offset", Gcal.parseRfc3339("2026-08-30T08:00:00-04:00"), 1788091200)
equal("rfc3339 fractional seconds", Gcal.parseRfc3339("2026-08-30T12:00:00.500Z"), 1788091200)
equal("rfc3339 rejects a bare date", Gcal.parseRfc3339("2026-08-30"), nil)

-- Gcal.next skips events that have already finished.
local now = os.time()
local today = os.date("%Y-%m-%d", now)
local upcoming = Gcal.next({
    { title = "over", all_day = false, start_epoch = now - 7200, end_epoch = now - 3600, day_key = today },
    { title = "next", all_day = false, start_epoch = now + 3600, end_epoch = now + 7200, day_key = today },
})
equal("next event skips the past", upcoming and upcoming.title, "next")

-- Batch protocol. Google prefixes the body with a CRLF before the first
-- delimiter; the fixture must carry it, or a parser anchored at position 1 looks
-- correct here and fails against the real API.
local batch_body = "\r\n" .. table.concat({
    "--batch_abc123",
    "Content-Type: application/http",
    "Content-ID: <response-item1>",
    "",
    "HTTP/1.1 200 OK",
    "Content-Type: application/json",
    "",
    '{"id":"m1","internalDate":"1788091200000","labelIds":["INBOX","UNREAD"],' ..
        '"snippet":"first","payload":{"headers":[{"name":"From","value":"Ada <ada@example.com>"},' ..
        '{"name":"Subject","value":"=?UTF-8?B?Q2Fmw6k=?="}]}}',
    "--batch_abc123",
    "Content-Type: application/http",
    "Content-ID: <response-item2>",
    "",
    "HTTP/1.1 404 Not Found",
    "Content-Type: application/json",
    "",
    '{"error":{"code":404,"message":"Not Found"}}',
    "--batch_abc123--",
    "",
}, "\r\n")

check("fixture reproduces Google's leading CRLF", batch_body:sub(1, 2) == "\r\n")

local parsed = Batch.parse(batch_body)
check("batch parses despite the leading CRLF", type(parsed) == "table")
equal("batch keeps the successful item", parsed[1] and parsed[1].id, "m1")
equal("batch drops the failed item", parsed[2], nil)

-- The response Content-Type is authoritative for the boundary.
local from_header = Batch.parse(batch_body,
    "multipart/mixed; boundary=batch_abc123")
equal("boundary read from the header", from_header and from_header[1] and from_header[1].id, "m1")

local quoted = Batch.parse(batch_body,
    'multipart/mixed; boundary="batch_abc123"; charset=UTF-8')
equal("quoted boundary in the header", quoted and quoted[1] and quoted[1].id, "m1")

-- A stale or wrong header boundary must not cost the caller a network refetch:
-- fall back to the body's own delimiter. (Google picks a new boundary per
-- response, so a mismatch here is a real possibility, not a hypothetical.)
local mismatched = Batch.parse(batch_body, "multipart/mixed; boundary=stale_xyz")
equal("recovers from a wrong header boundary",
      mismatched and mismatched[1] and mismatched[1].id, "m1")

-- The request side: one part per path, correctly delimited.
local built = Batch.buildBody({ "/gmail/v1/a", "/gmail/v1/b" })
equal("body opens with the delimiter", built:sub(1, #Batch.REQUEST_BOUNDARY + 2),
      "--" .. Batch.REQUEST_BOUNDARY)
equal("one Content-ID per path", select(2, built:gsub("Content%-ID:", "")), 2)
check("sub-requests carry their path", built:find("GET /gmail/v1/b", 1, true) ~= nil)
check("body is terminated", built:sub(-#Batch.REQUEST_BOUNDARY - 6) ==
      "--" .. Batch.REQUEST_BOUNDARY .. "--\r\n")
equal("an empty batch still terminates", select(2, Batch.buildBody({}):gsub("Content%-ID:", "")), 0)

local _bad, batch_err = Batch.parse("not multipart at all")
equal("batch rejects a non-multipart body", _bad, nil)
check("batch error is reported", batch_err ~= nil)

-- Query building.
equal("encodeQuery escapes", Http.encodeQuery{ q = "in:inbox is:unread" },
      "q=in%3Ainbox%20is%3Aunread")
equal("url with no params is unchanged", Http.url("https://x/y"), "https://x/y")
check("url appends with & when a query exists",
      Http.url("https://x/y?a=1", { b = 2 }) == "https://x/y?a=1&b=2")

-- Formatting.
equal("clip leaves short text alone", Fmt.clip("hello", 10), "hello")
equal("clip truncates with an ellipsis", Fmt.clip("hello world", 8), "hello w…")
equal("clip collapses whitespace", Fmt.clip("a\n  b", 10), "a b")
equal("dayHeading today", Fmt.dayHeading(os.date("%Y-%m-%d")), "Today")
equal("dayHeading tomorrow", Fmt.dayHeading(os.date("%Y-%m-%d", os.time() + 86400)), "Tomorrow")

-- Grid date arithmetic. All of this is deliberately os.time-free, so it cannot
-- drift with the device timezone or a DST boundary.
equal("dayKeyToDays round-trips", Gcal.daysToDayKey(Gcal.dayKeyToDays("2026-08-30")), "2026-08-30")
equal("dayKeyToDays at the epoch", Gcal.dayKeyToDays("1970-01-01"), 0)
equal("daysToDayKey at the epoch", Gcal.daysToDayKey(0), "1970-01-01")
equal("round-trips across a leap day", Gcal.daysToDayKey(Gcal.dayKeyToDays("2024-02-29")), "2024-02-29")
equal("round-trips across a century", Gcal.daysToDayKey(Gcal.dayKeyToDays("1900-03-01")), "1900-03-01")

-- 1970-01-01 was a Thursday (wday 5, counting Sunday as 1).
equal("weekday of the epoch", Gcal.weekdayOf("1970-01-01"), 5)
equal("weekday Sunday", Gcal.weekdayOf("2026-08-30"), 1)
equal("weekday Monday", Gcal.weekdayOf("2026-08-31"), 2)
equal("weekday Saturday", Gcal.weekdayOf("2026-09-05"), 7)

equal("days in February, common year", Gcal.daysInMonth(2026, 2), 28)
equal("days in February, leap year", Gcal.daysInMonth(2024, 2), 29)
equal("1900 is not a leap year", Gcal.daysInMonth(1900, 2), 28)
equal("2000 is a leap year", Gcal.daysInMonth(2000, 2), 29)

-- August 2026: the 1st is a Saturday, so a Monday-start grid needs 6 rows.
local august = Gcal.monthDays(2026, 8, 2)
equal("month grid is whole weeks", #august % 7, 0)
equal("August 2026 needs six rows", #august, 42)
equal("grid starts on the chosen weekday", Gcal.weekdayOf(august[1].key), 2)
equal("grid starts before the 1st", august[1].key, "2026-07-27")
check("leading cells are marked outside", august[1].outside == true)
equal("the 1st is in the grid", august[6].key, "2026-08-01")
check("the 1st is not outside", august[6].outside == false)
equal("grid ends after the 31st", august[#august].key, "2026-09-06")
check("trailing cells are marked outside", august[#august].outside == true)

-- February 2027 starts on a Monday and has 28 days: exactly four rows.
local february = Gcal.monthDays(2027, 2, 2)
equal("a four-row month", #february, 28)
check("no outside cells in a four-row month",
      february[1].outside == false and february[28].outside == false)

-- Sunday-start grids shift by one.
local sunday_start = Gcal.monthDays(2026, 8, 1)
equal("Sunday-start grid begins on a Sunday", Gcal.weekdayOf(sunday_start[1].key), 1)
equal("Sunday-start grid begins earlier", sunday_start[1].key, "2026-07-26")

local week = Gcal.weekDays("2026-09-02", 2)
equal("week has seven days", #week, 7)
equal("week starts on Monday", week[1].key, "2026-08-31")
equal("week ends on Sunday", week[7].key, "2026-09-06")
equal("week crosses the month boundary", week[3].day, 2)

local buckets = Gcal.bucketByDay({
    { day_key = "2026-08-30", all_day = false, start_epoch = 200, title = "late" },
    { day_key = "2026-08-30", all_day = true, title = "all day" },
    { day_key = "2026-08-30", all_day = false, start_epoch = 100, title = "early" },
    { day_key = "2026-08-31", all_day = false, start_epoch = 50, title = "next day" },
})
equal("bucket groups by day", #buckets["2026-08-30"], 3)
equal("all-day sorts first", buckets["2026-08-30"][1].title, "all day")
equal("timed events sort by start", buckets["2026-08-30"][2].title, "early")
equal("other days are separate", #buckets["2026-08-31"], 1)
check("empty days are absent", buckets["2026-09-01"] == nil)

-- Grid geometry. cellAt turns a tap into a day, and its two off-by-one risks
-- (the row above the grid, the column past the seventh) are what these pin down.
local CalendarGrid = require("ui/calendargrid")

local function fakeGrid(fields)
    local grid = {
        mode = "month", anchor = "2026-08-15", start_dow = 2,
        grid_top = 100, row_height = 150, day_width = 200,
        rule = 1, cell_padding = 8, outer_padding = 20, rows = 6,
    }
    for key, value in pairs(fields or {}) do grid[key] = value end
    grid.row_stride = grid.row_stride or (grid.row_height + grid.rule)
    grid.col_stride = grid.col_stride or (grid.day_width + grid.rule)
    return setmetatable(grid, { __index = CalendarGrid })
end

local grid = fakeGrid()
equal("grid cells match the month", #grid:cells(), 42)
equal("first cell of the grid", grid:cells()[1].key, "2026-07-27")

equal("tap in the first cell", grid:cellAt(20, 100).key, "2026-07-27")
equal("tap in the second column", grid:cellAt(20 + 201, 100).key, "2026-07-28")
equal("tap at the right edge of a cell", grid:cellAt(20 + 199, 100).key, "2026-07-27")
equal("tap in the seventh column", grid:cellAt(20 + 6 * 201, 100).key, "2026-08-02")
equal("tap in the second row", grid:cellAt(20, 100 + 151).key, "2026-08-03")
equal("tap in the last cell", grid:cellAt(20 + 6 * 201, 100 + 5 * 151).key, "2026-09-06")
equal("tap above the grid misses", grid:cellAt(20, 40), nil)
equal("tap past the seventh column misses", grid:cellAt(20 + 7 * 201, 100), nil)
equal("tap below the last row misses", grid:cellAt(20, 100 + 6 * 151), nil)

-- A week grid is the same widget with one row.
local week_grid = fakeGrid{ mode = "week", anchor = "2026-09-02", rows = 1, row_height = 900 }
equal("week grid has seven cells", #week_grid:cells(), 7)
equal("week grid starts on Monday", week_grid:cells()[1].key, "2026-08-31")
equal("tap in a week cell", week_grid:cellAt(20 + 201, 100).key, "2026-09-01")

-- Line budget: row_height 150, 8px padding each side, day number 30, line 28.
equal("event lines fit the cell", grid:linesPerCell(30, 28), 3)
equal("a tall week cell fits many lines", week_grid:linesPerCell(30, 28), 30)
equal("a cell too short for any event", fakeGrid{ row_height = 30 }:linesPerCell(30, 28), 0)
check("the line budget is never negative", fakeGrid{ row_height = 1 }:linesPerCell(30, 28) >= 0)

-- The grid must not shadow its own hairline() method with a numeric field.
check("hairline is callable on an instance", type(grid.hairline) == "function")

-- Gmail rejects an empty label list encoded as a JSON object with
-- "Invalid value (add_label_ids), Starting an object on a scalar field".
-- Every modify call has one empty side, so the empty side must be omitted.
local add_only = Gmail._modifyPayload({ "UNREAD" }, nil)
equal("an add-only payload carries addLabelIds", add_only.addLabelIds[1], "UNREAD")
check("an add-only payload omits removeLabelIds", add_only.removeLabelIds == nil)

local remove_only = Gmail._modifyPayload({}, { "UNREAD" })
equal("a remove-only payload carries removeLabelIds", remove_only.removeLabelIds[1], "UNREAD")
check("an empty add side is omitted, not sent as {}", remove_only.addLabelIds == nil)

local both = Gmail._modifyPayload({ "STARRED" }, { "INBOX" })
check("both sides survive when both are used",
      both.addLabelIds[1] == "STARRED" and both.removeLabelIds[1] == "INBOX")
check("a payload with nothing to do is empty", next(Gmail._modifyPayload(nil, nil)) == nil)

-- HTML mail: the CSS inside <style> survives tag-stripping, which is how raw
-- stylesheet text ended up in message bodies.
local dirty = [[<html><head><style>.a{color:red;background:#fff}</style></head>]] ..
    [[<body><!-- ping --><img src="http://x/p.gif"><p>Hello <b>you</b></p>]] ..
    [[<script>var a=1;</script></body></html>]]
local clean = MimeUtil.sanitizeHtml(dirty)
check("stylesheet text is gone", not clean:find("color:red", 1, true))
check("script text is gone", not clean:find("var a", 1, true))
check("images are gone", not clean:find("p.gif", 1, true))
check("comments are gone", not clean:find("ping", 1, true))
check("body text survives", clean:find("Hello", 1, true) ~= nil)
check("inline markup survives", clean:find("<b>", 1, true) ~= nil)
check("a tag that merely starts with style is untouched",
      MimeUtil.sanitizeHtml("<styled>keep me</styled>"):find("keep me", 1, true) ~= nil)
equal("non-string input is tolerated", MimeUtil.sanitizeHtml(nil), "")

-- 12-hour clock. Built without %-I/%p, so these must hold on every libc.
local function at(hour, minute)
    -- A local-time timestamp, so os.date("*t") reads back the same wall clock.
    return os.time{ year = 2026, month = 8, day = 30, hour = hour, min = minute, sec = 0 }
end
equal("clock12 afternoon", Fmt.clock12(at(17, 20)), "5:20 PM")
equal("clock12 morning", Fmt.clock12(at(9, 5)), "9:05 AM")
equal("clock12 midnight is 12 AM", Fmt.clock12(at(0, 0)), "12:00 AM")
equal("clock12 noon is 12 PM", Fmt.clock12(at(12, 0)), "12:00 PM")
equal("clock12 on nil", Fmt.clock12(nil), "")

-- The agenda window: the start of the current week through seven days ahead.
-- 2026-08-30 is a Sunday, so a Monday-start week runs back to the 24th.
local sunday = os.time{ year = 2026, month = 8, day = 30, hour = 12 }
local first_key, last_key = Gcal.windowKeys(2, sunday)
equal("window starts on the week's Monday", first_key, "2026-08-24")
equal("window ends seven days out", last_key, "2026-09-06")
local sun_first = Gcal.windowKeys(1, sunday)
equal("a Sunday-start week starts on the day itself", sun_first, "2026-08-30")

local windowed = Gcal.withinWindow({
    { day_key = "2026-08-23" },   -- last week
    { day_key = "2026-08-24" },   -- first day in
    { day_key = "2026-09-06" },   -- last day in
    { day_key = "2026-09-07" },   -- past the horizon
}, 2, sunday)
equal("window keeps only what it covers", #windowed, 2)
equal("window keeps its first day", windowed[1].day_key, "2026-08-24")
equal("window keeps its last day", windowed[2].day_key, "2026-09-06")

check("a wider fetch covers the window",
      Gcal.coversWindow("2026-08-01", "2026-09-30", 2, sunday))
check("an exact fetch covers the window",
      Gcal.coversWindow("2026-08-24", "2026-09-06", 2, sunday))
check("a fetch ending early does not cover it",
      not Gcal.coversWindow("2026-08-01", "2026-09-05", 2, sunday))
check("a fetch starting late does not cover it",
      not Gcal.coversWindow("2026-08-25", "2026-09-30", 2, sunday))

-- Card pagination. Pure given measured blocks, so it is exercised directly
-- rather than through a layout the stub harness cannot measure.
local EventList = require("ui/eventlist")
local function pagesOf(blocks, content_height)
    local pager = { content_height = content_height, card_gap = 10,
                    paginate = EventList.paginate }
    return pager:paginate(blocks)
end
local function shapeOf(pages)
    local shape = {}
    for _i, page in ipairs(pages) do shape[#shape + 1] = #page end
    return table.concat(shape, ",")
end

local card = function(h) return { height = h } end
local heading = function(h) return { height = h, heading = true } end

equal("no blocks still yields one page", #pagesOf({}, 100), 1)
equal("blocks that fit stay on one page",
      shapeOf(pagesOf({ card(30), card(30) }, 100)), "2")
-- 30 + 10 + 30 + 10 + 30 = 110 > 100, so the third card turns the page.
equal("an overflowing block starts a new page",
      shapeOf(pagesOf({ card(30), card(30), card(30) }, 100)), "2,1")
-- The heading fits after the first card, but its event does not follow it, so
-- both move rather than leaving the heading stranded at the foot of the page.
equal("a heading is never orphaned",
      shapeOf(pagesOf({ card(50), heading(20), card(40) }, 100)), "1,2")
-- A heading already alone at the top of a page has nowhere to move to.
equal("a lone heading stays put",
      shapeOf(pagesOf({ heading(20), card(90), card(90) }, 100)), "2,1")
equal("a trailing heading is not moved for a block that does not exist",
      shapeOf(pagesOf({ card(50), heading(20) }, 100)), "2")

-- Opening straight to a saved search, for the Home widget's mail box and the
-- calendar's Inbox button.
local MailList = require("ui/maillist")
equal("unread resolves to its view", MailList.indexOfView("unread"), 2)
equal("inbox resolves to its view", MailList.indexOfView("inbox"), 1)
equal("an unknown view key resolves to nothing", MailList.indexOfView("spam"), nil)
equal("no view key resolves to nothing", MailList.indexOfView(nil), nil)
check("a nil key falls back to Inbox", MailList.new({}, nil).view_index == 1)
check("a bad key falls back to Inbox", MailList.new({}, "spam").view_index == 1)
check("a good key is honoured", MailList.new({}, "unread").view_index == 2)

-- The icons ship with the plugin; KOReader's own set has no mail or calendar
-- glyph and silently substitutes "icon not found" for an unknown name, so a
-- missing file here would be invisible on the device.
local Icons = require("lib/icons")
check("the mail icon is present", Icons.path("mail") ~= nil)
check("the calendar icon is present", Icons.path("calendar") ~= nil)
equal("an unknown icon resolves to nothing", Icons.path("nope"), nil)

-- The ZenOS navbar. The stub screen is 800 tall.
local ZenOS = require("lib/zenos")

--- Stands in for the globals zenos.koplugin publishes.
local function fakeZenOS(navbar_config, height)
    _G.__ZEN_UI_NAVBAR_OPEN_TAB = function() return true end
    _G.__ZEN_UI_PLUGIN = { config = { navbar = navbar_config } }
    _G.__ZEN_UI_NAVBAR_HEIGHT = height
end

local function noZenOS()
    _G.__ZEN_UI_NAVBAR_OPEN_TAB = nil
    _G.__ZEN_UI_PLUGIN = nil
    _G.__ZEN_UI_NAVBAR_HEIGHT = nil
end

noZenOS()
equal("no ZenOS means no bar", ZenOS.navbarHeight(), 0)
equal("no ZenOS means no tabs", ZenOS.tabs(), nil)
check("openTab reports failure without ZenOS", not ZenOS.openTab("home"))

-- A height with no way to navigate is not a bar worth drawing.
_G.__ZEN_UI_NAVBAR_HEIGHT = 96
equal("a height alone is not enough", ZenOS.navbarHeight(), 0)

fakeZenOS({ tab_order = { "books", "home" }, books_label = "", home_label = "" }, 96)
equal("a configured bar takes its published height", ZenOS.navbarHeight(), 96)
local tabs = ZenOS.tabs()
equal("both tabs are drawn", #tabs, 2)
equal("tab order is ZenOS's", tabs[1].id, "books")
equal("a built-in tab gets its icon", tabs[1].icon, "library")
equal("a built-in tab gets its label", tabs[2].label, "Home")
check("openTab hands over to ZenOS", ZenOS.openTab("home"))

-- Renamed tabs, and the two ZenOS lets the user rename.
fakeZenOS({ tab_order = { "books", "home" }, books_label = "Shelf", home_label = "" }, 96)
tabs = ZenOS.tabs()
equal("a renamed library tab keeps the new name", tabs[1].label, "Shelf")
equal("an unrenamed home tab keeps the default", tabs[2].label, "Home")

-- Paging tabs act on the file list, which is not what is on our screen.
fakeZenOS({ tab_order = { "page_left", "home", "page_right" } }, 96)
tabs = ZenOS.tabs()
equal("paging tabs are dropped", #tabs, 1)
equal("the survivor is the real destination", tabs[1].id, "home")

-- A custom tab ZenOS was configured with but we have no built-in entry for.
fakeZenOS({
    tab_order = { "custom_1" },
    custom_tabs = { { id = "custom_1", label = "Work", icon = "tab_tags" } },
}, 96)
tabs = ZenOS.tabs()
equal("a custom tab is carried through", tabs[1].label, "Work")
equal("a custom tab keeps its icon", tabs[1].icon, "tab_tags")

fakeZenOS({ tab_order = { "custom_2" }, custom_tabs = { { id = "custom_2", tag = "SciFi" } } }, 96)
equal("an unlabelled custom tab falls back to its tag", ZenOS.tabs()[1].label, "SciFi")
equal("an unlabelled custom tab falls back to a ZenOS icon", ZenOS.tabs()[1].icon, "zen_ui")

-- An id in tab_order that matches nothing at all is skipped, not drawn blank.
fakeZenOS({ tab_order = { "home", "who_knows" } }, 96)
equal("an unknown tab id is dropped", #ZenOS.tabs(), 1)

-- Bad or missing heights.
fakeZenOS({ tab_order = { "home" } }, 600)
equal("an implausible height is ignored", ZenOS.navbarHeight(), 0)
fakeZenOS({ tab_order = { "home" } }, "tall")
equal("a non-numeric height is ignored", ZenOS.navbarHeight(), 0)
fakeZenOS({ tab_order = { "home" } }, 0)
equal("a zero height draws no bar", ZenOS.navbarHeight(), 0)
fakeZenOS({}, 96)
equal("a bar with no tabs is no bar", ZenOS.navbarHeight(), 0)
noZenOS()

-- Modern HTML mail. What breaks crengine is fixed-width nested layout tables,
-- inline CSS that positions or recolours text, and hidden preheaders.
local marketing = [[
<!DOCTYPE html>
<html xmlns:o="urn:schemas-microsoft-com:office:office">
<head><style>.btn{color:#fff;display:flex}</style><title>Newsletter</title></head>
<body style="margin:0;background:#eee">
<div style="display:none;font-size:1px;color:#eee">Preheader you should not read</div>
<!--[if mso]><table><tr><td>Outlook only</td></tr></table><![endif]-->
<table width="600" cellpadding="0" cellspacing="0" border="0" bgcolor="#ffffff">
  <tbody>
    <tr><td width="600" style="padding:20px" align="center">
      <table width="560"><tr><td>&nbsp;</td></tr>
        <tr><td><h1 style="font-size:48px;color:#ffffff">Big news</h1></td></tr>
        <tr><td><p style="color:#333" class="body">Hello <b>there</b>, read on.</p></td></tr>
        <tr><td><a href="https://track.example/x?u=1" style="color:#fff" target="_blank">Read more</a></td></tr>
      </table>
    </td></tr>
    <tr><td><img src="https://track.example/pixel.gif" width="1" height="1" alt=""></td></tr>
  </tbody>
</table>
<o:p></o:p>
</body></html>
]]
local clean = MimeUtil.sanitizeHtml(marketing)

check("stylesheet rules are gone", not clean:find("display:flex", 1, true))
check("the title is gone", not clean:find("Newsletter", 1, true))
check("the hidden preheader is gone", not clean:find("Preheader", 1, true))
check("the Outlook-only copy is gone", not clean:find("Outlook only", 1, true))
check("the tracking pixel is gone", not clean:find("pixel.gif", 1, true))
check("no table tags survive", not clean:lower():find("<table", 1, true))
check("no row tags survive", not clean:lower():find("<tr", 1, true))
check("no cell tags survive", not clean:lower():find("<td", 1, true))
check("no office namespace tags survive", not clean:lower():find("<o:", 1, true))
check("no style attribute survives", not clean:lower():find("style=", 1, true))
check("no width attribute survives", not clean:lower():find("width=", 1, true))
check("no class attribute survives", not clean:lower():find("class=", 1, true))
check("no bgcolor attribute survives", not clean:lower():find("bgcolor", 1, true))
check("the doctype is gone", not clean:lower():find("doctype", 1, true))
check("body wrapper is unwrapped", not clean:lower():find("<body", 1, true))

check("the heading survives", clean:find("Big news", 1, true) ~= nil)
check("the heading keeps its tag", clean:lower():find("<h1>", 1, true) ~= nil)
check("the paragraph survives", clean:find("Hello", 1, true) ~= nil)
check("inline emphasis survives", clean:find("<b>", 1, true) ~= nil)
check("link text survives", clean:find("Read more", 1, true) ~= nil)
check("cells became blocks", clean:find("<div>", 1, true) ~= nil)
check("nbsp spacer cells left nothing behind", not clean:find("&nbsp;", 1, true))

-- Line breaks are the one place a self-closing marker matters.
local broken = MimeUtil.sanitizeHtml([[<p>one<br style="clear:both"/>two<br>three</p>]])
check("a self-closing break stays self-closing", broken:find("<br />", 1, true) ~= nil)
check("break text survives", broken:find("two", 1, true) ~= nil)

-- Lists and quotes are meaning, not decoration.
local structure = MimeUtil.sanitizeHtml(
    [[<ul class="x"><li style="color:red">one</li><li>two</li></ul><blockquote>said</blockquote>]])
check("lists survive", structure:find("<li>", 1, true) ~= nil)
check("quotes survive", structure:find("<blockquote>", 1, true) ~= nil)
check("list styling is gone", not structure:find("color:red", 1, true))

-- Event handlers and data attributes are never content.
local scripted = MimeUtil.sanitizeHtml([[<div onclick="steal()" data-id="7">safe</div>]])
check("event handlers are gone", not scripted:find("steal", 1, true))
check("data attributes are gone", not scripted:find("data-id", 1, true))
check("the text is kept", scripted:find("safe", 1, true) ~= nil)

equal("non-string input is still tolerated", MimeUtil.sanitizeHtml(nil), "")

-- Base64, written out rather than taken from LuaSocket's chunked mime.b64.
equal("base64 of one byte pads twice", MimeUtil.encodeBase64("a"), "YQ==")
equal("base64 of two bytes pads once", MimeUtil.encodeBase64("ab"), "YWI=")
equal("base64 of three bytes does not pad", MimeUtil.encodeBase64("abc"), "YWJj")
equal("base64 of empty input", MimeUtil.encodeBase64(""), "")
equal("base64 round trip", MimeUtil.decodeBase64Url(MimeUtil.encodeBase64("Hello, world!")),
      "Hello, world!")
equal("base64 handles high bytes", MimeUtil.encodeBase64(string.char(0xFF, 0xEF)), "/+8=")
-- The url-safe alphabet swaps those two characters and drops the padding.
equal("base64url swaps + and /", MimeUtil.encodeBase64Url(string.char(0xFF, 0xEF)), "_-8")
equal("base64url round trip",
      MimeUtil.decodeBase64Url(MimeUtil.encodeBase64Url("Café ☕")), "Café ☕")
equal("base64 wraps at 76 characters",
      #MimeUtil.wrapBase64(string.rep("A", 100), "\r\n"), 100 + 2)

-- RFC 2047: encode only what has to be encoded.
equal("an ascii subject is left alone", MimeUtil.encodeHeaderWord("Weekly report"),
      "Weekly report")
equal("a non-ascii subject is encoded", MimeUtil.encodeHeaderWord("Café"),
      "=?UTF-8?B?Q2Fmw6k=?=")
equal("an encoded subject decodes back",
      MimeUtil.decodeHeader(MimeUtil.encodeHeaderWord("Café ☕")), "Café ☕")

-- Address lists: the display name is encoded, the address never is.
equal("an ascii address list is left alone",
      MimeUtil.encodeAddressList("ada@example.com, bob@example.com"),
      "ada@example.com, bob@example.com")
local encoded_list = MimeUtil.encodeAddressList('"Café Owner" <cafe@example.com>')
check("the address survives encoding", encoded_list:find("<cafe@example.com>", 1, true) ~= nil)
check("the display name is encoded", encoded_list:find("=?UTF-8?B?", 1, true) ~= nil)
local two_up = MimeUtil.encodeAddressList('"Zoë" <z@example.com>, bob@example.com')
check("a second plain address is preserved",
      two_up:find("bob@example.com", 1, true) ~= nil)
-- A comma inside a quoted display name must not split the list.
local quoted = MimeUtil.encodeAddressList('"Doe, Jané" <jane@example.com>')
check("a comma inside quotes does not split", quoted:find("<jane@example.com>", 1, true) ~= nil)
check("only one address came out", select(2, quoted:gsub("<", "<")) == 1)

-- Building a message.
local ComposeLib = require("lib/compose")
local raw = ComposeLib.build{
    from = "me@example.com", to = "ada@example.com", subject = "Hi",
    body = "line one\nline two", epoch = 0,
}
check("the From header is set", raw:find("From: me@example.com", 1, true) ~= nil)
check("the To header is set", raw:find("To: ada@example.com", 1, true) ~= nil)
check("the Subject header is set", raw:find("Subject: Hi", 1, true) ~= nil)
check("headers are CRLF separated", raw:find("\r\n", 1, true) ~= nil)
check("the transfer encoding is declared",
      raw:find("Content-Transfer-Encoding: base64", 1, true) ~= nil)
check("the charset is declared", raw:find('charset="UTF-8"', 1, true) ~= nil)
check("an empty Cc is omitted", not raw:find("Cc:", 1, true))
check("an empty In-Reply-To is omitted", not raw:find("In-Reply-To", 1, true))
equal("the date is rendered in UTC", ComposeLib.date(0), "Thu, 01 Jan 1970 00:00:00 +0000")

-- The body is the base64 after the blank line separating it from the headers.
local body64 = raw:match("\r\n\r\n(.*)$"):gsub("\r\n", "")
equal("the body round trips", MimeUtil.decodeBase64Url(body64), "line one\nline two")

-- A header value may never carry its own line break: anything after one would
-- be read as a header of its own. The break is folded to a space, so the text
-- stays on the To line as an unusable address rather than becoming a real Bcc.
local injected = ComposeLib.build{ to = "a@b.c\r\nBcc: sneak@evil.example", body = "" }
local function hasHeaderLine(raw_message, name)
    for line in (raw_message .. "\r\n"):gmatch("(.-)\r\n") do
        if line == "" then return false end -- headers end at the blank line
        if line:lower():sub(1, #name + 1) == name:lower() .. ":" then return true end
    end
    return false
end
check("the injected line never becomes a header", not hasHeaderLine(injected, "Bcc"))
check("it is folded into the To line instead",
      injected:find("To: a@b.c Bcc: sneak@evil.example", 1, true) ~= nil)
check("a real header is still found by the same test", hasHeaderLine(injected, "To"))

-- Replies.
local original = {
    id = "m1", thread_id = "t1", subject = "Lunch",
    from = "Ada", from_address = "ada@example.com",
    to = "me@example.com, bob@example.com", cc = "carol@example.com",
    body = "Are you free?", timestamp = 0, message_id = "<abc@mail>",
}
local reply = ComposeLib.reply(original, { self_address = "me@example.com" })
equal("a reply goes to the sender", reply.to, "ada@example.com")
equal("a reply prefixes the subject", reply.subject, "Re: Lunch")
equal("a reply threads", reply.in_reply_to, "<abc@mail>")
check("a reply quotes the original", reply.body:find("> Are you free?", 1, true) ~= nil)
check("a reply attributes the quote", reply.body:find("Ada wrote:", 1, true) ~= nil)
equal("a plain reply has no Cc", reply.cc, "")

local reply_all = ComposeLib.reply(original, { all = true, self_address = "me@example.com" })
check("reply-all keeps the other recipients",
      reply_all.cc:find("bob@example.com", 1, true) ~= nil)
check("reply-all keeps those on Cc", reply_all.cc:find("carol@example.com", 1, true) ~= nil)
check("reply-all does not Cc ourselves", not reply_all.cc:find("me@example.com", 1, true))
check("reply-all does not Cc the person being replied to",
      not reply_all.cc:find("ada@example.com", 1, true))

-- Re: is added once, however many rounds it has been through.
equal("Re: is not doubled",
      ComposeLib.reply({ subject = "Re: Lunch", from_address = "a@b.c" }, {}).subject,
      "Re: Lunch")
equal("a lowercase re: also counts",
      ComposeLib.reply({ subject = "re: Lunch", from_address = "a@b.c" }, {}).subject,
      "re: Lunch")

-- Reply-To wins over From when the sender asked for it.
equal("Reply-To is honoured",
      ComposeLib.reply({ reply_to = "list@example.com", from_address = "bounce@example.com" },
                       {}).to,
      "list@example.com")

-- Forwarding.
local forwarded = ComposeLib.forward(original)
equal("a forward prefixes the subject", forwarded.subject, "Fwd: Lunch")
equal("a forward has no recipient yet", forwarded.to, "")
check("a forward inlines the original", forwarded.body:find("Are you free?", 1, true) ~= nil)
check("a forward keeps the original sender",
      forwarded.body:find("ada@example.com", 1, true) ~= nil)

-- The mail views the compose work added.
equal("sent has a view", MailList.indexOfView("sent") ~= nil, true)
equal("drafts has a view", MailList.indexOfView("drafts") ~= nil, true)
check("only the drafts view opens the composer",
      MailList.VIEWS[MailList.indexOfView("drafts")].drafts == true
      and MailList.VIEWS[MailList.indexOfView("sent")].drafts == nil)

-- ZenOS launchability: mirrors zen-os modules/menu/app_launcher/plugin_scan.lua,
-- which is what decides whether this plugin can be added as a navbar tab.
local GoogleSuite = require("main")

local LAUNCH_METHODS = { "onShow", "show", "open", "launch", "onOpen" }
local launch_method
for _i, method in ipairs(LAUNCH_METHODS) do
    if type(GoogleSuite[method]) == "function" then
        launch_method = method
        break
    end
end
check("ZenOS finds a launch method", launch_method ~= nil,
      "none of onShow/show/open/launch/onOpen is callable")

-- The scanner probes addToMainMenu with a throwaway table, so it must be
-- side-effect free and must produce an entry the scanner can title and call.
local probe = {}
local probed_ok, probe_err = pcall(GoogleSuite.addToMainMenu, GoogleSuite, probe)
check("addToMainMenu survives a bare probe", probed_ok, probe_err)
local entry = probe.google_suite
check("probe yields a menu entry", type(entry) == "table")
check("menu entry has a callback", entry and type(entry.callback) == "function")
check("menu entry has a title", entry and type(entry.text) == "string" and entry.text ~= "")

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
