--[[--
Disk cache so every view can paint immediately and refresh afterwards.

A Kindle spends most of its life with Wi-Fi off, so "last known inbox" and
"last known agenda" are what the user actually sees nine times out of ten.
--]]

local DataStorage = require("datastorage")
local Persist = require("persist")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Const = require("lib/const")

local Cache = {}

local function cacheDir()
    local dir = DataStorage:getDataDir() .. "/" .. Const.CACHE_DIR
    if not lfs.attributes(dir, "mode") then
        lfs.mkdir(dir)
    end
    return dir
end

local function store(key)
    return Persist:new{ path = cacheDir() .. "/" .. key .. ".lua" }
end

--- @treturn table|nil data, number age in seconds
function Cache.get(key, max_age)
    local persist = store(key)
    if not persist:exists() then return nil end
    local record = persist:load()
    if type(record) ~= "table" or record.data == nil then return nil end
    local age = os.time() - (record.saved_at or 0)
    if max_age and age > max_age then return nil, age end
    return record.data, age
end

function Cache.set(key, data)
    local ok, err = store(key):save({ saved_at = os.time(), data = data })
    if not ok then logger.warn("GoogleSuite: cache write failed", key, err) end
    return ok
end

function Cache.delete(key)
    local persist = store(key)
    if persist:exists() then persist:delete() end
end

--- Drops every entry whose key starts with `prefix`, or all of them if omitted.
--- Called with no prefix on sign-out, so a second account never sees the first
--- one's mail; called with one when a setting invalidates only part of the cache.
function Cache.clear(prefix)
    local dir = cacheDir()
    for entry in lfs.dir(dir) do
        local key = entry:match("^(.*)%.lua$")
        if key and (not prefix or key:sub(1, #prefix) == prefix) then
            os.remove(dir .. "/" .. entry)
        end
    end
end

function Cache.clearAll()
    Cache.clear()
end

return Cache
