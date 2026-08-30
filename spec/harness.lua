-- Minimal KOReader stand-in so the plugin's modules can be loaded and the pure
-- logic exercised outside the device. Anything not explicitly stubbed resolves
-- to a permissive proxy, which is enough for load-time checks.

local plugin_root = (arg[0]:match("^(.*)/spec/[^/]+%.lua$") or ".") .. "/google_suite.koplugin"
package.path = plugin_root .. "/?.lua;" .. package.path

local real_require = require

local function proxy(name)
    local t = {}
    setmetatable(t, {
        __index = function(_, key)
            local child = proxy(name .. "." .. tostring(key))
            rawset(t, key, child)
            return child
        end,
        __call = function(_, ...) return proxy(name .. "()") end,
        __tostring = function() return "<stub " .. name .. ">" end,
    })
    return t
end

local gettext = setmetatable({}, { __call = function(_, text) return text end })

local function template(text, ...)
    local args = { ... }
    return (text:gsub("%%(%d)", function(index) return tostring(args[tonumber(index)]) end))
end

local OWN_UI = {
    ["ui/task"] = true, ["ui/setup"] = true, ["ui/maillist"] = true,
    ["ui/mailview"] = true, ["ui/agenda"] = true, ["ui/appview"] = true,
    ["ui/homewidget"] = true, ["ui/calendargrid"] = true,
}

-- Layout code does arithmetic on these, so they must be numbers, not proxies.
local function numeric(value)
    return setmetatable({}, { __index = function() return value end })
end

local stubs = {
    ["ui/size"] = {
        padding = numeric(8), border = numeric(2), span = numeric(6),
        margin = numeric(4), item = numeric(40), line = numeric(1), radius = numeric(4),
    },
    ["gettext"] = gettext,
    ["ffi/util"] = { template = template },
    ["logger"] = { dbg = function() end, warn = function() end, err = function() end, info = function() end },
    ["json"] = real_require("spec.json"),
    ["socket.url"] = {
        escape = function(text)
            return (tostring(text):gsub("[^%w%-%._~]", function(c)
                return string.format("%%%02X", c:byte())
            end))
        end,
    },
    ["mime"] = real_require("spec.b64"),
    ["util"] = real_require("spec.util"),
}

_G.require = function(name)
    if stubs[name] then return stubs[name] end
    -- Only the plugin's own modules; KOReader also has flat `ui/...` names.
    if name:match("^lib/") or OWN_UI[name] then
        return real_require(name)
    end
    local ok, module = pcall(real_require, name)
    if ok then return module end
    local stub = proxy(name)
    stubs[name] = stub
    return stub
end

return { plugin_root = plugin_root }
