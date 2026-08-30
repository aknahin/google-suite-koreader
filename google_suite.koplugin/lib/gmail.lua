--[[--
Gmail: list, read, and triage.

`users.messages.list` only returns ids, so a second call per message is needed
for headers. Those go out in one batched request via `lib/batch.lua`, which also
carries the fallback if Google's batch format ever shifts.
--]]

local JSON = require("json")
local util = require("util")
local _ = require("gettext")

local Account = require("lib/account")
local Batch = require("lib/batch")
local Const = require("lib/const")
local Http = require("lib/http")
local MimeUtil = require("lib/mimeutil")

local Gmail = {}

local BATCH_URL = "https://gmail.googleapis.com/batch/gmail/v1"
local METADATA_HEADERS = { "From", "To", "Subject", "Date" }

local function messagesUrl(path, params)
    return Http.url(Const.GMAIL_API .. "/users/me/messages" .. (path or ""), params)
end

local function hasLabel(message, label)
    for _i, id in ipairs(message.labelIds or {}) do
        if id == label then return true end
    end
    return false
end

--- Turns a raw Gmail message resource into the flat shape the UI wants.
local function summarize(message)
    local headers = message.payload and message.payload.headers
    local from_name, from_address = MimeUtil.parseAddress(MimeUtil.header(headers, "From"))
    return {
        id        = message.id,
        thread_id = message.threadId,
        snippet   = message.snippet and util.htmlEntitiesToUtf8(message.snippet) or "",
        from      = from_name,
        from_address = from_address,
        subject   = MimeUtil.decodeHeader(MimeUtil.header(headers, "Subject") or ""),
        timestamp = math.floor((tonumber(message.internalDate) or 0) / 1000),
        unread    = hasLabel(message, "UNREAD"),
        starred   = hasLabel(message, "STARRED"),
        in_inbox  = hasLabel(message, "INBOX"),
    }
end

--- Metadata for a page of ids in one batched request. Google caps a batch at
--- 100 sub-requests; `Batch.fetch` splits and falls back on its own.
local function fetchMetadata(ids)
    local items = {}
    for _i, id in ipairs(ids) do
        local query = "format=metadata&" .. Http.encodeQuery{ metadataHeaders = METADATA_HEADERS }
        items[#items + 1] = {
            path = "/gmail/v1/users/me/messages/" .. id .. "?" .. query,
            url  = messagesUrl("/" .. id, {
                format = "metadata",
                metadataHeaders = METADATA_HEADERS,
            }),
        }
    end
    return Batch.fetch(BATCH_URL, items, _("Fetching mail… %1 of %2"))
end

--[[--
List messages matching a Gmail search query.

@tparam table opts query (string, e.g. "in:inbox"), max (number), page_token (string)
@treturn table { messages = {summary, ...}, next_page_token = string|nil }
--]]
function Gmail.list(opts)
    opts = opts or {}
    local page, err = Account:request{
        url = messagesUrl(nil, {
            q = opts.query or "in:inbox",
            maxResults = opts.max or 25,
            pageToken = opts.page_token,
        }),
    }
    if not page then return nil, err end

    local ids = {}
    for _i, entry in ipairs(page.messages or {}) do ids[#ids + 1] = entry.id end
    if #ids == 0 then
        return { messages = {}, next_page_token = nil }
    end

    local raw, batch_err = fetchMetadata(ids)
    if not raw then return nil, batch_err end

    local messages = {}
    for index = 1, #ids do
        local message = raw[index]
        if message then messages[#messages + 1] = summarize(message) end
    end
    table.sort(messages, function(a, b) return a.timestamp > b.timestamp end)
    return { messages = messages, next_page_token = page.nextPageToken }
end

--- Depth-first search of the MIME tree for the best readable body part.
local function findBody(part, wanted)
    if not part then return nil end
    if part.mimeType == wanted and part.body and part.body.data then
        return part.body.data
    end
    for _i, child in ipairs(part.parts or {}) do
        local found = findBody(child, wanted)
        if found then return found end
    end
end

--- Full message including a plain-text rendering of the body.
function Gmail.get(id)
    local message, err = Account:request{ url = messagesUrl("/" .. id, { format = "full" }) }
    if not message then return nil, err end

    local summary = summarize(message)
    summary.to = MimeUtil.decodeHeader(MimeUtil.header(message.payload and message.payload.headers, "To") or "")

    -- Keep both renderings available: the viewer picks by user preference, and
    -- falls back to text if the HTML turns out to be empty after sanitizing.
    local plain = findBody(message.payload, "text/plain")
    local html = findBody(message.payload, "text/html")
    if html then
        summary.html = MimeUtil.sanitizeHtml(MimeUtil.decodeBase64Url(html))
    end
    if plain then
        summary.body = MimeUtil.decodeBase64Url(plain)
    elseif summary.html then
        summary.body = util.htmlToPlainText(summary.html)
    end
    if not summary.body or summary.body:gsub("%s", "") == "" then
        summary.body = summary.snippet
    end

    local attachments = {}
    local function collect(part)
        for _i, child in ipairs((part and part.parts) or {}) do
            if child.filename and child.filename ~= "" then
                attachments[#attachments + 1] = child.filename
            end
            collect(child)
        end
    end
    collect(message.payload)
    summary.attachments = attachments
    return summary
end

--- Builds the modify payload, omitting empty sides. Exposed for tests.
function Gmail._modifyPayload(add, remove)
    local payload = {}
    if add and #add > 0 then payload.addLabelIds = add end
    if remove and #remove > 0 then payload.removeLabelIds = remove end
    return payload
end

--[[--
Add and/or remove labels.

An empty Lua table encodes as `{}`, not `[]`, and Gmail rejects that with
*"Invalid value (add_label_ids), Starting an object on a scalar field"* — so a
side with nothing in it is omitted from the payload rather than sent empty.
Every modify call has one empty side, so this is not an edge case.

@treturn bool true, or nil plus a message
--]]
function Gmail.modify(id, add, remove)
    local payload = Gmail._modifyPayload(add, remove)
    if next(payload) == nil then return true end

    local response, err = Account:request{
        url = messagesUrl("/" .. id .. "/modify"),
        method = "POST",
        headers = { ["Content-Type"] = "application/json" },
        body = JSON.encode(payload),
    }
    if not response then return nil, err end
    return true
end



function Gmail.trash(id)
    local response, err = Account:request{
        url = messagesUrl("/" .. id .. "/trash"),
        method = "POST",
        headers = { ["Content-Length"] = "0" },
    }
    if not response then return nil, err end
    return true
end

return Gmail
