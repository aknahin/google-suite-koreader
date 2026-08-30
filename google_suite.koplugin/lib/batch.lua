--[[--
Google's multipart batch protocol, shared by Gmail and Calendar.

Both APIs need the same fan-out: Gmail fetches metadata for a page of message
ids, Calendar fetches events from every selected calendar. Done one request at a
time that is 20-25 TLS handshakes per refresh, which on a Kindle's radio is the
difference between a usable view and a hung one. Batched it is a single request.

KOReader ships `frontend/httpasync.lua`, which could parallelise instead, but it
hardcodes `verify = "none"` — a bearer token does not go over an unverified
socket.
--]]

local JSON = require("json")
local logger = require("logger")
local T = require("ffi/util").template
local _ = require("gettext")

local Account = require("lib/account")

local Batch = {}

Batch.REQUEST_BOUNDARY = "koreader_google_suite_batch"

--- Google recommends no more than 50 sub-requests, and caps a batch at 100.
Batch.MAX_ITEMS = 50

--- Builds a multipart/mixed body of GET sub-requests.
-- @tparam table paths list of API paths, e.g. "/gmail/v1/users/me/messages/abc"
function Batch.buildBody(paths)
    local parts = {}
    for index, path in ipairs(paths) do
        parts[#parts + 1] = table.concat({
            "--" .. Batch.REQUEST_BOUNDARY,
            "Content-Type: application/http",
            "Content-ID: <item" .. index .. ">",
            "",
            "GET " .. path,
            "",
        }, "\r\n")
    end
    parts[#parts + 1] = "--" .. Batch.REQUEST_BOUNDARY .. "--\r\n"
    return table.concat(parts, "\r\n")
end

--- Walks one multipart body with a known delimiter.
local function parseWithBoundary(body, boundary)
    local results = {}
    local delimiter = "--" .. boundary
    local cursor = 1
    while true do
        local start_pos = body:find(delimiter, cursor, true)
        if not start_pos then break end
        local body_start = start_pos + #delimiter
        local next_pos = body:find(delimiter, body_start, true)
        local chunk = body:sub(body_start, (next_pos or #body + 1) - 1)
        cursor = next_pos or (#body + 1)

        -- A chunk is: part headers, blank line, then a complete HTTP response.
        local index = chunk:match("Content%-ID:%s*<?response%-item(%d+)")
        local status, json_body = chunk:match("HTTP/[%d%.]+ (%d+)[^\r\n]*\r\n.-\r\n\r\n(.*)$")
        if index and status == "200" and json_body then
            local ok, decoded = pcall(JSON.decode, json_body)
            if ok and type(decoded) == "table" then
                results[tonumber(index)] = decoded
            end
        elseif index then
            logger.dbg("GoogleSuite: batch item", index, "failed with status", status)
        end
        if not next_pos then break end
    end
    return results
end

--[[--
Splits a batch response into { [sub_request_index] = decoded_body }.

Google picks a fresh boundary per response and, crucially, **prefixes the body
with a CRLF** before the first delimiter, so the boundary cannot be read with a
pattern anchored at position 1. The response's own Content-Type is authoritative,
but a boundary that parses nothing is worth nothing: fall back to the body's
first non-empty line rather than making the caller refetch over the network.
--]]
function Batch.parse(body, content_type)
    local candidates = {}
    if type(content_type) == "string" then
        candidates[#candidates + 1] = content_type:match('boundary="([^"]+)"')
            or content_type:match("boundary=([^;%s]+)")
    end
    candidates[#candidates + 1] = body:gsub("^[\r\n%s]+", ""):match("^%-%-([^\r\n]+)")

    local results
    for _i, boundary in ipairs(candidates) do
        results = parseWithBoundary(body, boundary)
        if next(results) ~= nil then return results end
    end
    if not results then
        return nil, _("Google returned an unexpected batch response.")
    end
    return results
end

--- One authorized GET per item; slow, but immune to any change in the batch
--- format. Used only when a batch comes back unusable.
local function fetchSequential(items, progress_text)
    local Trapper = require("ui/trapper")
    local results = {}
    for index, item in ipairs(items) do
        if progress_text and Trapper:isWrapped() then
            Trapper:info(T(progress_text, index, #items))
        end
        local response = Account:request{ url = item.url }
        if response then results[index] = response end
    end
    if next(results) == nil then
        return nil, _("Could not fetch anything from Google.")
    end
    return results
end

--[[--
Runs a batch, falling back to sequential requests if it comes back unusable.

@tparam string endpoint the API's batch URL
@tparam table items list of { path = "/api/v1/...", url = "https://..." }
@tparam[opt] string progress_text a T() template taking (done, total)
@treturn table { [item_index] = decoded_body }
--]]
function Batch.fetch(endpoint, items, progress_text)
    if #items == 0 then return {} end
    if #items > Batch.MAX_ITEMS then
        -- Split rather than risk Google rejecting an oversized batch.
        local merged = {}
        for offset = 0, #items - 1, Batch.MAX_ITEMS do
            local slice = {}
            for i = offset + 1, math.min(offset + Batch.MAX_ITEMS, #items) do
                slice[#slice + 1] = items[i]
            end
            local part, err = Batch.fetch(endpoint, slice, progress_text)
            if not part then return nil, err end
            for index, value in pairs(part) do merged[offset + index] = value end
        end
        return merged
    end

    local paths = {}
    for _i, item in ipairs(items) do paths[#paths + 1] = item.path end

    local body, headers = Account:request{
        url = endpoint,
        method = "POST",
        headers = { ["Content-Type"] = "multipart/mixed; boundary=" .. Batch.REQUEST_BOUNDARY },
        body = Batch.buildBody(paths),
        raw = true,
        total_timeout = 60,
    }
    if not body then return nil, headers end

    local content_type = type(headers) == "table"
        and (headers["content-type"] or headers["Content-Type"]) or nil
    local results = Batch.parse(body, content_type)
    if results and next(results) ~= nil then return results end

    -- Log enough to diagnose without spilling anyone's data into the log.
    logger.warn("GoogleSuite: batch response unusable; content-type",
                tostring(content_type), "length", #body, "head", body:sub(1, 120))
    return fetchSequential(items, progress_text)
end

return Batch
