--[[--
Runs blocking network work behind a dismissable progress popup.

Every entry point goes through here so the Kindle's Wi-Fi is brought up on
demand rather than the UI simply hanging with the radio off.
--]]

local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")

local Task = {}

--[[--
@tparam string text shown while the work runs
@tparam function work called in a coroutine; returns (result, error_message)
@tparam function on_done called with (result, error_message) once finished
--]]
function Task.run(text, work, on_done)
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            Trapper:info(text)
            local result, err = work()
            Trapper:clear()
            on_done(result, err)
        end)
    end)
end

function Task.notify(message, timeout)
    UIManager:show(InfoMessage:new{ text = message, timeout = timeout or 3 })
end

function Task.error(message)
    UIManager:show(InfoMessage:new{ text = message, icon = "notice-warning" })
end

return Task
