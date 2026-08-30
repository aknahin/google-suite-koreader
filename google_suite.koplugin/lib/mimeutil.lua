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
Strips everything from an HTML mail that should never reach the reader.

KOReader's `util.htmlToPlainText` only removes tags, so the *contents* of
`<style>` survive the conversion — which is why raw CSS was showing up in the
message body. Removing those elements wholesale fixes the plain-text path and
also makes the HTML safe to hand to the renderer, which cannot fetch remote
images anyway.
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

function MimeUtil.sanitizeHtml(html)
    if type(html) ~= "string" then return "" end
    local text = html:gsub("<!%-%-.-%-%->", " ")
    for _i, tag in ipairs({ "script", "style", "head", "title", "noscript" }) do
        text = dropElement(text, tag)
    end
    -- Images cannot be fetched on-device; leaving them draws broken-image boxes.
    text = text:gsub("<%s*" .. anyCase("img") .. "%f[%W].-/?>", " ")
    -- Layout tables and tracking pixels leave long runs of spacing behind.
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
