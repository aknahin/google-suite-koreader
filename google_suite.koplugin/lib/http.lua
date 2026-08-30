--[[--
Thin JSON-over-HTTPS client.

Modelled on `plugins/wallabag.koplugin/main.lua` (`Wallabag:callAPI`), which is
KOReader's reference implementation for token-authenticated JSON APIs, with one
addition: KOReader never configures LuaSec, so by default certificates are *not*
verified. We carry OAuth refresh tokens, so we pass explicit SSL parameters and
our own root bundle (`data/roots.pem`, from https://pki.goog/roots.pem).
--]]

local JSON = require("json")
local http = require("socket.http")
local ltn12 = require("ltn12")
local logger = require("logger")
local socket = require("socket")
local socketutil = require("socketutil")
local url = require("socket.url")

local Http = {}

local function pluginRoot()
    local source = debug.getinfo(1, "S").source or ""
    return source:match("^@(.*)/lib/[^/]+%.lua$")
end

Http.CAFILE = (pluginRoot() or ".") .. "/data/roots.pem"

--- Set false only to diagnose a TLS problem; it turns off certificate checking.
Http.verify_certificates = true

local function sslParams()
    if not Http.verify_certificates then
        return { protocol = "any", verify = "none", options = { "all", "no_sslv2", "no_sslv3" } }
    end
    return {
        protocol = "any",
        verify   = "peer",
        cafile   = Http.CAFILE,
        options  = { "all", "no_sslv2", "no_sslv3", "no_tlsv1" },
    }
end

--- Describes a failure in a way the UI can show verbatim.
-- @tparam string kind one of "network", "http", "json"
local function fail(kind, message, code, body)
    return nil, { kind = kind, message = message, code = code, body = body }
end

--[[--
Perform one request.

@tparam table o
    url       (string, required)
    method    (string, default "GET")
    headers   (table, optional)
    body      (string, optional; sets Content-Length)
    raw       (bool, optional; return the body as a string instead of decoding JSON)
    block_timeout / total_timeout (numbers, optional)
@treturn table decoded JSON response (empty table for an empty 2xx body), or the
    raw body string plus the response headers when `raw` is set
@treturn table error descriptor when the first return is nil
--]]
function Http.request(o)
    local headers = {}
    for k, v in pairs(o.headers or {}) do headers[k] = v end
    headers["Accept"] = headers["Accept"] or "application/json"

    local sink = {}
    local request = {
        url     = o.url,
        method  = o.method or "GET",
        headers = headers,
        sink    = socketutil.table_sink(sink),
    }
    for k, v in pairs(sslParams()) do request[k] = v end

    if o.body then
        headers["Content-Length"] = tostring(#o.body)
        request.source = ltn12.source.string(o.body)
    end

    socketutil:set_timeout(o.block_timeout or socketutil.LARGE_BLOCK_TIMEOUT,
                           o.total_timeout or socketutil.LARGE_TOTAL_TIMEOUT)
    local code, resp_headers, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()

    if resp_headers == nil then
        -- No response at all: offline, DNS failure, timeout, or a rejected certificate.
        logger.warn("GoogleSuite: request failed", o.method or "GET", o.url, status or code)
        return fail("network", tostring(status or code or "network error"))
    end

    local content = table.concat(sink)
    local decoded
    if content ~= "" and (not o.raw or type(code) ~= "number" or code < 200 or code >= 300) then
        local ok, result = pcall(JSON.decode, content)
        if ok then decoded = result end
    end

    if type(code) ~= "number" or code < 200 or code >= 300 then
        local message
        if type(decoded) == "table" and type(decoded.error) == "table" then
            message = decoded.error.message
        elseif type(decoded) == "table" and type(decoded.error) == "string" then
            -- The token endpoint uses {"error": "...", "error_description": "..."}.
            message = decoded.error_description or decoded.error
        end
        return fail("http", message or tostring(status or code), code, decoded)
    end

    if o.raw then
        return content, resp_headers
    end
    if content ~= "" and decoded == nil then
        return fail("json", "response was not valid JSON", code)
    end
    return decoded or {}
end

--- URL-encodes a table into a query string. Array values repeat the key.
function Http.encodeQuery(params)
    local parts = {}
    for k, v in pairs(params) do
        if type(v) == "table" then
            for _, item in ipairs(v) do
                parts[#parts + 1] = url.escape(k) .. "=" .. url.escape(tostring(item))
            end
        elseif v ~= nil then
            parts[#parts + 1] = url.escape(k) .. "=" .. url.escape(tostring(v))
        end
    end
    return table.concat(parts, "&")
end

--- Appends a query string to a URL.
function Http.url(base, params)
    if not params or next(params) == nil then return base end
    return base .. (base:find("?", 1, true) and "&" or "?") .. Http.encodeQuery(params)
end

return Http
