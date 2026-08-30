-- Stand-in for KOReader's rapidjson binding: just enough decode/encode for tests.
local M = {}

local function skipSpace(text, pos)
    local _, stop = text:find("^[ \t\r\n]*", pos)
    return stop + 1
end

local decodeValue

local ESCAPES = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f",
                  n = "\n", r = "\r", t = "\t" }

local function utf8Char(code)
    if code < 0x80 then return string.char(code) end
    if code < 0x800 then
        return string.char(0xC0 + math.floor(code / 64), 0x80 + code % 64)
    end
    return string.char(0xE0 + math.floor(code / 4096),
                       0x80 + math.floor(code / 64) % 64,
                       0x80 + code % 64)
end

local function decodeString(text, pos)
    local out = {}
    pos = pos + 1
    while true do
        local char = text:sub(pos, pos)
        if char == "" then error("unterminated string") end
        if char == '"' then return table.concat(out), pos + 1 end
        if char == "\\" then
            local escape = text:sub(pos + 1, pos + 1)
            if escape == "u" then
                out[#out + 1] = utf8Char(tonumber(text:sub(pos + 2, pos + 5), 16))
                pos = pos + 6
            else
                out[#out + 1] = ESCAPES[escape] or escape
                pos = pos + 2
            end
        else
            out[#out + 1] = char
            pos = pos + 1
        end
    end
end

decodeValue = function(text, pos)
    pos = skipSpace(text, pos)
    local char = text:sub(pos, pos)
    if char == "{" then
        local object = {}
        pos = skipSpace(text, pos + 1)
        if text:sub(pos, pos) == "}" then return object, pos + 1 end
        while true do
            local key
            key, pos = decodeString(text, skipSpace(text, pos))
            pos = skipSpace(text, pos)
            pos = pos + 1 -- ':'
            object[key], pos = decodeValue(text, pos)
            pos = skipSpace(text, pos)
            local delimiter = text:sub(pos, pos)
            pos = pos + 1
            if delimiter == "}" then return object, pos end
            if delimiter ~= "," then error("expected , or } at " .. pos) end
        end
    elseif char == "[" then
        local array = {}
        pos = skipSpace(text, pos + 1)
        if text:sub(pos, pos) == "]" then return array, pos + 1 end
        while true do
            array[#array + 1], pos = decodeValue(text, pos)
            pos = skipSpace(text, pos)
            local delimiter = text:sub(pos, pos)
            pos = pos + 1
            if delimiter == "]" then return array, pos end
            if delimiter ~= "," then error("expected , or ] at " .. pos) end
        end
    elseif char == '"' then
        return decodeString(text, pos)
    elseif text:sub(pos, pos + 3) == "true" then
        return true, pos + 4
    elseif text:sub(pos, pos + 4) == "false" then
        return false, pos + 5
    elseif text:sub(pos, pos + 3) == "null" then
        return nil, pos + 4
    else
        local number = text:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
        if not number then error("unexpected input at " .. pos) end
        return tonumber(number), pos + #number
    end
end

function M.decode(text)
    local value = decodeValue(text, 1)
    return value
end

local function encodeValue(value, out)
    local kind = type(value)
    if kind == "table" then
        if #value > 0 or next(value) == nil then
            out[#out + 1] = "["
            for index, item in ipairs(value) do
                if index > 1 then out[#out + 1] = "," end
                encodeValue(item, out)
            end
            out[#out + 1] = "]"
        else
            out[#out + 1] = "{"
            local first = true
            for key, item in pairs(value) do
                if not first then out[#out + 1] = "," end
                first = false
                out[#out + 1] = '"' .. tostring(key) .. '":'
                encodeValue(item, out)
            end
            out[#out + 1] = "}"
        end
    elseif kind == "string" then
        out[#out + 1] = '"' .. value:gsub('[\\"]', "\\%0"):gsub("\n", "\\n") .. '"'
    else
        out[#out + 1] = tostring(value)
    end
end

function M.encode(value)
    local out = {}
    encodeValue(value, out)
    return table.concat(out)
end

return M
