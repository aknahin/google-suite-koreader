--[[--
The MIME decoding Gmail's REST API leaves to the client: base64url bodies,
quoted-printable, and RFC 2047 encoded-words in headers.
--]]

local mime = require("mime")

local MimeUtil = {}

--- Gmail returns message bodies base64url-encoded and unpadded.
function MimeUtil.decodeBase64Url(text)
    if type(text) ~= "string" or text == "" then return "" end
    local standard = text:gsub("-", "+"):gsub("_", "/"):gsub("%s", "")
    local padding = (4 - #standard % 4) % 4
    return mime.unb64(standard .. string.rep("=", padding)) or ""
end

function MimeUtil.decodeQuotedPrintable(text)
    return (text:gsub("=\r?\n", "")
                :gsub("=(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
end

--- Latin-1 bytes are valid UTF-8 only below 0x80; widen the rest.
local function latin1ToUtf8(text)
    return (text:gsub("[\128-\255]", function(char)
        local byte = char:byte()
        return string.char(0xC0 + math.floor(byte / 64), 0x80 + byte % 64)
    end))
end

local function recode(text, charset)
    charset = (charset or "utf-8"):lower()
    if charset == "iso-8859-1" or charset == "latin1" or charset == "windows-1252" then
        return latin1ToUtf8(text)
    end
    return text
end

local function decodeWord(charset, encoding, payload)
    local decoded
    if encoding:upper() == "B" then
        decoded = mime.unb64(payload) or ""
    else
        decoded = MimeUtil.decodeQuotedPrintable(payload:gsub("_", " "))
    end
    return recode(decoded, charset)
end

--[[--
Decodes RFC 2047 encoded-words, e.g.
`=?UTF-8?B?Q2Fmw6k=?=` or `=?ISO-8859-1?Q?Caf=E9?=`.
Whitespace between two adjacent encoded-words is dropped, per the RFC.
--]]
function MimeUtil.decodeHeader(text)
    if type(text) ~= "string" or not text:find("=?", 1, true) then return text end
    local joined = text:gsub("(%?=)%s+(=%?)", "%1%2")
    return (joined:gsub("=%?([%w%-_]+)%?([BbQq])%?(.-)%?=", decodeWord))
end

--- Splits `Ada Lovelace <ada@example.com>` into its display name and address.
function MimeUtil.parseAddress(header)
    if type(header) ~= "string" then return "", "" end
    header = MimeUtil.decodeHeader(header)
    local name, address = header:match('^%s*"?(.-)"?%s*<(.-)>%s*$')
    if name and name ~= "" then return name, address end
    if address then return address, address end
    local bare = header:match("^%s*(.-)%s*$")
    return bare, bare
end

--[[--
Turns an HTML mail into something KOReader's renderer can lay out.

crengine is an EPUB engine: it renders a document, not a viewport. Mail built
the way mail is built — nested fixed-width layout tables, inline CSS positioning,
`display:none` preheaders, colour on colour — either overflows a 6" screen a word
per line or paints text that is not there. And `util.htmlToPlainText` only
removes tags, so the *contents* of `<style>` survive into the plain-text path,
which is why raw CSS was showing up in message bodies.

So the markup is reduced to what actually carries meaning: paragraphs, headings,
lists, emphasis, links and line breaks. Everything decorative goes.

The one judgement call is tables, which are flattened into stacked blocks. In
mail they are almost always scaffolding rather than data, and a 600px-wide
scaffold on a 600px screen is what breaks the layout; a genuine data table loses
its columns, which is the lesser harm on a screen this narrow.
--]]

--- Lua patterns have no case-insensitive flag, so build one: "img" -> "[iI][mM][gG]".
local function anyCase(word)
    return (word:gsub("%a", function(c) return "[" .. c:upper() .. c:lower() .. "]" end))
end

--- Removes an element and everything inside it.
local function dropElement(text, tag)
    local name = anyCase(tag)
    -- %f[%W] is a frontier pattern: it stops <style> from also matching <styled>.
    return (text:gsub("<%s*" .. name .. "%f[%W].-</%s*" .. name .. "%s*>", " "))
end

--- Removes a tag but keeps whatever it wrapped.
local function unwrapElement(text, tag, replacement)
    local name = anyCase(tag)
    text = text:gsub("<%s*" .. name .. "%f[%W][^>]*>", replacement or "")
    return (text:gsub("</%s*" .. name .. "%s*>", replacement or ""))
end

--- Elements whose content is markup, styling or chrome rather than the message.
local DROP_WITH_CONTENT = {
    "script", "style", "head", "title", "noscript", "iframe", "object", "embed",
    "svg", "video", "audio", "form", "select", "textarea", "button", "canvas",
    "applet", "map",
}

--- Empty elements that only ever contributed layout or a remote fetch. Images
--- go too: nothing can be fetched on-device, and what is left is a broken-image
--- box on every tracking pixel.
local DROP_EMPTY = {
    "img", "input", "link", "meta", "base", "col", "source", "track", "area",
    "param", "hr",
}

--- Table scaffolding, flattened into stacked blocks.
local TABLE_TO_BLOCK = { "table", "thead", "tbody", "tfoot", "tr", "caption", "colgroup" }
local CELL_TO_BLOCK = { "td", "th" }

--- Attributes that carry presentation. `style` is the one that matters most:
--- crengine honours enough of it to place text off-screen or paint it white.
local DROP_ATTRS = {
    "style", "class", "id", "width", "height", "bgcolor", "background", "align",
    "valign", "border", "cellpadding", "cellspacing", "color", "face", "size",
    "dir", "lang", "role", "target", "rel", "srcset", "sizes",
}

--- Anything left inside a tag after the attributes we name have been removed,
--- e.g. Outlook's `mso-*` and every `data-*` and `on*` handler.
local function stripAttributes(tag_body)
    local body = tag_body
    for _i, attr in ipairs(DROP_ATTRS) do
        local name = anyCase(attr)
        body = body:gsub("%s+" .. name .. "%s*=%s*\"[^\"]*\"", "")
        body = body:gsub("%s+" .. name .. "%s*=%s*'[^']*'", "")
        body = body:gsub("%s+" .. name .. "%s*=%s*[^%s>]+", "")
    end
    -- data-* and on* (onclick, onload) never mean anything here.
    body = body:gsub("%s+[dD][aA][tT][aA]%-[%w%-]+%s*=%s*\"[^\"]*\"", "")
    body = body:gsub("%s+[dD][aA][tT][aA]%-[%w%-]+%s*=%s*'[^']*'", "")
    body = body:gsub("%s+[oO][nN]%a+%s*=%s*\"[^\"]*\"", "")
    body = body:gsub("%s+[oO][nN]%a+%s*=%s*'[^']*'", "")
    return body
end

--[[--
Drops elements the sender hid: preheaders, and the alternate copies mail clients
are meant to pick between.

Matched non-greedily, so a hidden block containing another block of the same name
closes early and leaves a stray end tag behind. crengine ignores those, and
leaving a little extra is much better than swallowing the message.
--]]
local function dropHidden(text)
    local hidden = "[^>]*[sS][tT][yY][lL][eE]%s*=%s*[\"'][^\"']*"
    for _i, tag in ipairs({ "div", "span", "p", "td", "table" }) do
        local name = anyCase(tag)
        for _j, rule in ipairs({ "[dD][iI][sS][pP][lL][aA][yY]%s*:%s*[nN][oO][nN][eE]",
                                 "[vV][iI][sS][iI][bB][iI][lL][iI][tT][yY]%s*:%s*[hH][iI][dD][dD][eE][nN]" }) do
            text = text:gsub("<%s*" .. name .. hidden .. rule .. ".-</%s*" .. name .. "%s*>", " ")
        end
    end
    return text
end

function MimeUtil.sanitizeHtml(html)
    if type(html) ~= "string" then return "" end

    -- Conditional comments (<!--[if mso]>) are comments, so this takes the
    -- Outlook-only copy of the message with them.
    local text = html:gsub("<!%-%-.-%-%->", " ")
    text = text:gsub("<!%s*[dD][oO][cC][tT][yY][pP][eE][^>]*>", " ")

    for _i, tag in ipairs(DROP_WITH_CONTENT) do
        text = dropElement(text, tag)
    end
    text = dropHidden(text)
    for _i, tag in ipairs(DROP_EMPTY) do
        text = text:gsub("<%s*" .. anyCase(tag) .. "%f[%W][^>]*>", " ")
        text = text:gsub("</%s*" .. anyCase(tag) .. "%s*>", " ")
    end

    -- Office and VML namespaces: <o:p>, <v:shape>, <w:sdt>.
    text = text:gsub("<%s*/?%s*[ovwxOVWX]:[%w%-]+[^>]*>", " ")

    -- Flatten the scaffolding. Cells become blocks so their content still
    -- separates; the wrappers around them just go.
    for _i, tag in ipairs(TABLE_TO_BLOCK) do
        text = unwrapElement(text, tag, " ")
    end
    for _i, tag in ipairs(CELL_TO_BLOCK) do
        text = text:gsub("<%s*" .. anyCase(tag) .. "%f[%W][^>]*>", "<div>")
        text = text:gsub("</%s*" .. anyCase(tag) .. "%s*>", "</div>")
    end

    -- html and body wrappers: the caller supplies its own.
    for _i, tag in ipairs({ "html", "body", "font", "center", "main", "article",
                            "section", "header", "footer", "nav", "aside" }) do
        text = unwrapElement(text, tag, " ")
    end

    text = text:gsub("<(/?)([%a][%w]*)([^>]*)>", function(slash, name, body)
        if slash == "/" then return "</" .. name .. ">" end
        local kept = stripAttributes(body)
        -- Keep a self-closing marker; dropping it would leave <br> unclosed in
        -- a document crengine parses as XML-ish.
        local closing = kept:match("/%s*$") and " /" or ""
        kept = kept:gsub("%s*/%s*$", "")
        return "<" .. name .. kept .. closing .. ">"
    end)

    text = text:gsub("&[nN][bB][sS][pP];", " ")
    -- Spacer cells and tracking rows leave runs of empty blocks behind.
    for _i = 1, 4 do
        text = text:gsub("<div>%s*</div>", " ")
        text = text:gsub("<p>%s*</p>", " ")
        text = text:gsub("<span>%s*</span>", " ")
    end
    text = text:gsub("[ \t]+", " ")
    return text
end

--- Header lookup over Gmail's `payload.headers` array; case-insensitive.
function MimeUtil.header(headers, name)
    if type(headers) ~= "table" then return nil end
    local wanted = name:lower()
    for _i, entry in ipairs(headers) do
        if type(entry.name) == "string" and entry.name:lower() == wanted then
            return entry.value
        end
    end
end

return MimeUtil
