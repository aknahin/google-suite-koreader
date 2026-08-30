--[[--
Builds the RFC 2822 messages Gmail's `raw` field takes.

Plain text only. A Kindle keyboard is not somewhere anyone wants to write markup,
and a `text/plain` part renders correctly in every client there is; the reader
already prefers HTML for *receiving*, which is the direction that needs it.

The body goes out base64-encoded rather than as-is. Mail bodies wrap, fold and
mangle bare 8-bit text in transit, and a quoted reply arrives full of lines that
begin with `>` — which is exactly the shape a naive transfer encoding breaks on.
Base64 makes the whole question go away for the price of a few percent.
--]]

local MimeUtil = require("lib/mimeutil")
local _ = require("gettext")

local Compose = {}

local CRLF = "\r\n"

--- RFC 2822 date in UTC. Built with os.date's UTC flag so the offset we claim
--- and the time we print cannot disagree.
function Compose.date(epoch)
    return os.date("!%a, %d %b %Y %H:%M:%S +0000", epoch or os.time())
end

--- Header values must not carry their own line breaks; a header that did would
--- let anything after the newline be read as a header of its own.
local function sanitizeHeaderValue(value)
    return (tostring(value or ""):gsub("[\r\n]+", " "):gsub("^%s*(.-)%s*$", "%1"))
end

local function addHeader(out, name, value, encoder)
    local clean = sanitizeHeaderValue(value)
    if clean == "" then return end
    out[#out + 1] = name .. ": " .. encoder(clean)
end

local function verbatim(value) return value end

--[[--
A complete message, ready for `MimeUtil.encodeBase64Url`.

@tparam table fields
    from, to, cc, bcc  (string) address lists
    subject            (string)
    body               (string) plain text
    in_reply_to        (string) the Message-ID being answered
    references         (string) the thread's Message-ID chain
@treturn string
--]]
function Compose.build(fields)
    fields = fields or {}
    local out = {}

    addHeader(out, "From", fields.from, MimeUtil.encodeAddressList)
    addHeader(out, "To", fields.to, MimeUtil.encodeAddressList)
    addHeader(out, "Cc", fields.cc, MimeUtil.encodeAddressList)
    addHeader(out, "Bcc", fields.bcc, MimeUtil.encodeAddressList)
    addHeader(out, "Subject", fields.subject, MimeUtil.encodeHeaderWord)
    addHeader(out, "Date", Compose.date(fields.epoch), verbatim)

    -- Threading. Without these a reply starts a new conversation in every
    -- client, Gmail's own included.
    addHeader(out, "In-Reply-To", fields.in_reply_to, verbatim)
    addHeader(out, "References", fields.references, verbatim)

    out[#out + 1] = "MIME-Version: 1.0"
    out[#out + 1] = 'Content-Type: text/plain; charset="UTF-8"'
    out[#out + 1] = "Content-Transfer-Encoding: base64"
    out[#out + 1] = ""

    local body = (fields.body or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    out[#out + 1] = MimeUtil.wrapBase64(MimeUtil.encodeBase64(body), CRLF)
    return table.concat(out, CRLF)
end

-- ---------------------------------------------------------------- replying ---

--- "Re: " once, however many times it has been round already.
local function prefixSubject(prefix, subject)
    subject = subject or ""
    if subject:lower():sub(1, #prefix + 1) == prefix:lower() .. ":" then
        return subject
    end
    return prefix .. ": " .. subject
end

--- The original, quoted the way every mail client quotes it.
local function quote(message)
    local Fmt = require("lib/fmt")
    local attribution = string.format("On %s, %s wrote:",
        Fmt.dateTime(message.timestamp), message.from or message.from_address or "?")
    local lines = { "", "", attribution }
    for line in ((message.body or "") .. "\n"):gmatch("(.-)\n") do
        lines[#lines + 1] = "> " .. line
    end
    return table.concat(lines, "\n")
end

--- Every address on the message except our own, for a reply-all.
local function othersOn(message, self_address)
    local seen, out = {}, {}
    if self_address then seen[self_address:lower()] = true end
    local function add(list)
        for entry in (list or ""):gmatch("[^,]+") do
            local _name, address = MimeUtil.parseAddress(entry)
            if address and address ~= "" and not seen[address:lower()] then
                seen[address:lower()] = true
                out[#out + 1] = entry:match("^%s*(.-)%s*$")
            end
        end
    end
    add(message.to)
    add(message.cc)
    return table.concat(out, ", ")
end

--[[--
The prefilled fields for a reply.

@tparam table message a Gmail.get result
@tparam table opts  all (bool) reply to everyone, self_address (string)
@treturn table fields for Compose.build, plus a `body_cursor` line count so the
    editor can put the caret above the quoted text
--]]
function Compose.reply(message, opts)
    opts = opts or {}
    local to = message.reply_to
    if not to or to == "" then
        to = message.from_address or ""
    end
    local cc = ""
    if opts.all then
        cc = othersOn(message, opts.self_address)
        -- Whoever we are replying to does not also belong in Cc.
        local _name, to_address = MimeUtil.parseAddress(to)
        local kept = {}
        for entry in cc:gmatch("[^,]+") do
            local _n, address = MimeUtil.parseAddress(entry)
            if address:lower() ~= (to_address or ""):lower() then
                kept[#kept + 1] = entry:match("^%s*(.-)%s*$")
            end
        end
        cc = table.concat(kept, ", ")
    end

    return {
        to          = to,
        cc          = cc,
        subject     = prefixSubject("Re", message.subject),
        body        = quote(message),
        in_reply_to = message.message_id,
        references  = (message.references and message.references ~= "")
            and (message.references .. " " .. (message.message_id or ""))
            or message.message_id,
    }
end

--- The prefilled fields for a forward: no recipient, the original inlined.
function Compose.forward(message)
    local header = table.concat({
        "", "",
        _("---------- Forwarded message ----------"),
        "From: " .. (message.from or "") .. " <" .. (message.from_address or "") .. ">",
        "Date: " .. require("lib/fmt").dateTime(message.timestamp),
        "Subject: " .. (message.subject or ""),
        "To: " .. (message.to or ""),
        "",
    }, "\n")
    return {
        to      = "",
        subject = prefixSubject("Fwd", message.subject),
        body    = header .. (message.body or ""),
    }
end

return Compose
