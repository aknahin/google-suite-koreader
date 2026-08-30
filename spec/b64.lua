-- Stand-in for LuaSocket's `mime` module (b64/unb64 only).
local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local M = {}

function M.b64(data)
    if not data then return nil end
    local out = {}
    for index = 1, #data, 3 do
        local a, b, c = data:byte(index, index + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local chars = {
            ALPHABET:sub(math.floor(n / 262144) + 1, math.floor(n / 262144) + 1),
            ALPHABET:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1),
            b and ALPHABET:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1) or "=",
            c and ALPHABET:sub(n % 64 + 1, n % 64 + 1) or "=",
        }
        out[#out + 1] = table.concat(chars)
    end
    return table.concat(out)
end

function M.unb64(data)
    if not data then return nil end
    data = data:gsub("[^%w%+/=]", ""):gsub("=+$", "")
    local out = {}
    local bits, count = 0, 0
    for index = 1, #data do
        local value = ALPHABET:find(data:sub(index, index), 1, true)
        if value then
            bits = bits * 64 + (value - 1)
            count = count + 6
            if count >= 8 then
                count = count - 8
                local byte = math.floor(bits / 2 ^ count)
                out[#out + 1] = string.char(byte % 256)
                bits = bits % 2 ^ count
            end
        end
    end
    return table.concat(out)
end

return M
