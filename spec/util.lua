-- Stand-in for the handful of KOReader `util` helpers the plugin uses.
local M = {}

local ENTITIES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " " }

function M.htmlEntitiesToUtf8(text)
    return (text:gsub("&(%a+);", function(name) return ENTITIES[name] end))
end

function M.htmlToPlainText(text)
    text = text:gsub("<[bB][rR]%s*/?>", "\n")
    text = text:gsub("</[pP]>", "\n")
    text = text:gsub("<[^>]->", "")
    return M.htmlEntitiesToUtf8(text):gsub("\n%s*\n%s*\n+", "\n\n")
end

function M.htmlToPlainTextIfHtml(text)
    if text:find("<%a") then return M.htmlToPlainText(text) end
    return text
end

return M
