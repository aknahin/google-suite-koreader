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
    "lib/zenos",
    "ui/task", "ui/setup", "ui/sectionbutton", "ui/mailview", "ui/maillist",
    "ui/agenda", "ui/calendargrid", "ui/eventlist", "ui/homewidget",
    "ui/appview", "main",
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

-- ZenOS navbar reservation. The stub screen is 800 tall.
local ZenOS = require("lib/zenos")
_G.__ZEN_UI_NAVBAR_HEIGHT = nil
equal("no ZenOS means no reserved strip", ZenOS.navbarHeight(), 0)
equal("the page is the whole screen without ZenOS", ZenOS.pageHeight(), 800)
check("the page covers the screen without ZenOS", ZenOS.coversFullscreen())
_G.__ZEN_UI_NAVBAR_HEIGHT = 96
equal("a published navbar height is reserved", ZenOS.navbarHeight(), 96)
equal("the page stops above the navbar", ZenOS.pageHeight(), 704)
check("the page no longer covers the screen", not ZenOS.coversFullscreen())
_G.__ZEN_UI_NAVBAR_HEIGHT = 0
equal("a zero height reserves nothing", ZenOS.navbarHeight(), 0)
_G.__ZEN_UI_NAVBAR_HEIGHT = 600
equal("an implausible height is ignored", ZenOS.navbarHeight(), 0)
_G.__ZEN_UI_NAVBAR_HEIGHT = "tall"
equal("a non-numeric height is ignored", ZenOS.navbarHeight(), 0)
_G.__ZEN_UI_NAVBAR_HEIGHT = nil

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
