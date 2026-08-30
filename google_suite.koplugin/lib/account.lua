--[[--
Token storage and authorized requests.

Google's device ("limited-input") OAuth grant does not support Gmail or Calendar
scopes, so there is no way to complete a sign-in on the e-reader itself. Instead
`tools/google_auth.py` runs the ordinary loopback flow on a computer and writes a
token file, which the user imports here once. From then on this module only ever
does refresh-token grants, which need no browser.
--]]

local DataStorage = require("datastorage")
local JSON = require("json")
local LuaSettings = require("luasettings")
local logger = require("logger")
local T = require("ffi/util").template
local _ = require("gettext")

local Const = require("lib/const")
local Http = require("lib/http")

local Account = {
    access_token = nil,
    access_token_expiry = 0,
}

local REQUIRED_KEYS = { "client_id", "client_secret", "refresh_token" }

function Account:settings()
    if not self._settings then
        self._settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/" .. Const.SETTINGS_FILE .. ".lua")
    end
    return self._settings
end

function Account:isConfigured()
    return self:settings():readSetting("refresh_token") ~= nil
end

function Account:getEmail()
    return self:settings():readSetting("email")
end

--[[--
Import a token file produced by tools/google_auth.py.
@treturn bool success
@treturn string human-readable error
--]]
function Account:importTokenFile(path)
    local file = io.open(path, "r")
    if not file then return false, _("Could not open that file.") end
    local content = file:read("*a")
    file:close()

    local ok, data = pcall(JSON.decode, content)
    if not ok or type(data) ~= "table" then
        return false, _("That file is not valid JSON.")
    end
    for _i, key in ipairs(REQUIRED_KEYS) do
        if type(data[key]) ~= "string" or data[key] == "" then
            return false, T(_("The token file is missing %1."), key)
        end
    end

    local settings = self:settings()
    settings:saveSetting("client_id", data.client_id)
    settings:saveSetting("client_secret", data.client_secret)
    settings:saveSetting("refresh_token", data.refresh_token)
    settings:saveSetting("email", data.email)
    settings:flush()
    self.access_token, self.access_token_expiry = nil, 0

    -- Prove the credentials work before telling the user they are signed in.
    local token, err = self:getAccessToken()
    if not token then
        settings:delSetting("refresh_token")
        settings:flush()
        return false, err
    end
    if not data.email then
        local info = Http.request{
            url = Const.USERINFO_URL,
            headers = { ["Authorization"] = "Bearer " .. token },
        }
        if info and info.email then
            settings:saveSetting("email", info.email)
            settings:flush()
        end
    end
    return true
end

function Account:signOut(revoke)
    if revoke then
        local refresh_token = self:settings():readSetting("refresh_token")
        if refresh_token then
            Http.request{
                url = Const.REVOKE_URL,
                method = "POST",
                headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
                body = Http.encodeQuery{ token = refresh_token },
            }
        end
    end
    local settings = self:settings()
    for _i, key in ipairs(REQUIRED_KEYS) do settings:delSetting(key) end
    settings:delSetting("email")
    settings:flush()
    self.access_token, self.access_token_expiry = nil, 0
end

--- Exchanges the stored refresh token for an access token, caching until 60s before expiry.
function Account:getAccessToken(force)
    if not force and self.access_token and os.time() < self.access_token_expiry then
        return self.access_token
    end
    local settings = self:settings()
    local refresh_token = settings:readSetting("refresh_token")
    if not refresh_token then
        return nil, _("Not signed in.")
    end

    local response, err = Http.request{
        url = Const.TOKEN_URL,
        method = "POST",
        headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
        body = Http.encodeQuery{
            client_id     = settings:readSetting("client_id"),
            client_secret = settings:readSetting("client_secret"),
            refresh_token = refresh_token,
            grant_type    = "refresh_token",
        },
    }
    if not response then
        if err.kind == "http" and type(err.body) == "table" and err.body.error == "invalid_grant" then
            -- Revoked, expired (consent screen left in "Testing"), or password changed.
            self.needs_reauth = true
            return nil, _("Google rejected the saved sign-in. Run the helper script again and re-import the token file.")
        end
        return nil, err.message
    end

    self.access_token = response.access_token
    self.access_token_expiry = os.time() + (tonumber(response.expires_in) or 3600) - 60
    self.needs_reauth = false
    -- Google occasionally rotates the refresh token; keep the newest one.
    if response.refresh_token and response.refresh_token ~= refresh_token then
        settings:saveSetting("refresh_token", response.refresh_token)
        settings:flush()
    end
    return self.access_token
end

--[[--
Perform an authorized request, refreshing the access token once on a 401.

Return values match `Http.request`: on success the decoded body, or -- for a
`raw` request -- the body string plus the response headers, which the Gmail
batch parser needs in order to read the multipart boundary Google chose. On
failure, nil plus a plain string suitable for display.
--]]
function Account:request(o)
    local token, token_err = self:getAccessToken()
    if not token then return nil, token_err end

    local function attempt(bearer)
        local headers = {}
        for k, v in pairs(o.headers or {}) do headers[k] = v end
        headers["Authorization"] = "Bearer " .. bearer
        local opts = {}
        for k, v in pairs(o) do opts[k] = v end
        opts.headers = headers
        return Http.request(opts)
    end

    -- On success the second value is response headers, on failure it is the
    -- error descriptor; only the failure path may interpret it.
    local response, extra = attempt(token)
    if response then return response, extra end
    local err = extra

    if err.kind == "http" and err.code == 401 then
        logger.dbg("GoogleSuite: 401, refreshing access token")
        local fresh, fresh_err = self:getAccessToken(true)
        if not fresh then return nil, fresh_err end
        response, extra = attempt(fresh)
        if response then return response, extra end
        err = extra
    end

    if err.kind == "network" then
        return nil, _("Network error. Check the Wi-Fi connection.")
    elseif err.code == 403 or err.code == 429 then
        return nil, err.message or _("Google is rate-limiting this account. Try again shortly.")
    end
    return nil, err.message or _("Request failed.")
end

return Account
