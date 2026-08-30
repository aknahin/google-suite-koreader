--[[--
The icons this plugin ships with.

KOReader's own set (`resources/icons/mdlight`) has no mail or calendar glyph,
and `IconWidget{ icon = "mail" }` does not fail on an unknown name — it quietly
renders `icon-not-found`. So the SVGs live in `icons/` next to this file and are
loaded by path: `IconWidget` short-circuits to a plain `ImageWidget` whenever it
is handed a `file`, which skips name resolution entirely and needs neither
registration nor a copy into KOReader's user icons directory.
--]]

local IconWidget = require("ui/widget/iconwidget")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Icons = {}

--- This plugin's directory, taken from this file's own source path so it holds
--- wherever KOReader has the plugin installed.
local ROOT = debug.getinfo(1, "S").source:match("^@(.*)/lib/[^/]+%.lua$")

function Icons.path(name)
    if not ROOT then return nil end
    local path = ROOT .. "/icons/" .. name .. ".svg"
    if lfs.attributes(path, "mode") ~= "file" then return nil end
    return path
end

--- @treturn widget|nil an IconWidget `size` square, or nil if the file is gone
function Icons.get(name, size)
    local path = Icons.path(name)
    if not path then
        logger.warn("GoogleSuite: icon file missing", name)
        return nil
    end
    local ok, widget = pcall(IconWidget.new, IconWidget, {
        file   = path,
        width  = size,
        height = size,
        alpha  = true,
    })
    if ok and widget then return widget end
    logger.warn("GoogleSuite: icon failed to load", name, widget)
end

return Icons
