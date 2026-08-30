--[[--
The message list: one Menu, four saved searches, triage on long-press.
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local T = require("ffi/util").template
local _ = require("gettext")

local Cache = require("lib/cache")
local Fmt = require("lib/fmt")
local Gmail = require("lib/gmail")
local MailView = require("ui/mailview")
local Navbar = require("ui/navbar")
local SectionButton = require("ui/sectionbutton")
local Task = require("ui/task")

local MailList = {}
MailList.__index = MailList

MailList.VIEWS = {
    { key = "inbox",   title = _("Inbox"),    query = "in:inbox" },
    { key = "unread",  title = _("Unread"),   query = "in:inbox is:unread" },
    { key = "starred", title = _("Starred"),  query = "is:starred" },
    { key = "all",     title = _("All mail"), query = "in:anywhere" },
}

local CACHE_MAX_AGE = 6 * 3600

--- The index of a view key, or nil. Lets callers open straight to "unread".
function MailList.indexOfView(view_key)
    for index, view in ipairs(MailList.VIEWS) do
        if view.key == view_key then return index end
    end
end

--- @tparam table hub provides openAgenda() and openSettings()
--- @tparam string|nil view_key which saved search to open on; defaults to Inbox
function MailList.new(hub, view_key)
    return setmetatable({
        hub = hub,
        view_index = MailList.indexOfView(view_key) or 1,
        messages = {},
    }, MailList)
end

function MailList:view()
    return MailList.VIEWS[self.view_index]
end

function MailList:cacheKey()
    return "mail_" .. self:view().key
end

function MailList:itemTable()
    local items = {}
    for _i, message in ipairs(self.messages) do
        local marks = (message.unread and "● " or "") .. (message.starred and "★ " or "")
        items[#items + 1] = {
            text = marks .. Fmt.clip(message.from, 28) .. "  —  " .. Fmt.clip(message.subject, 70),
            mandatory = Fmt.shortDate(message.timestamp),
            bold = message.unread,
            message = message,
            index = _i,
        }
    end
    if #items == 0 then
        items[1] = { text = _("Nothing here."), select_enabled = false }
    end
    return items
end

function MailList:title()
    local suffix = self.stale_age and T(_(" (cached %1)"), Fmt.shortDate(os.time() - self.stale_age)) or ""
    return self:view().title .. suffix
end

function MailList:refreshItems()
    if self.menu then
        self.menu:switchItemTable(self:title(), self:itemTable())
    end
end

--- Loads from cache first so the list paints immediately, then hits the network.
function MailList:load(force)
    local cached, age = Cache.get(self:cacheKey(), force and 0 or CACHE_MAX_AGE)
    if cached and not force then
        self.messages = cached
        self.stale_age = age > 300 and age or nil
        self:refreshItems()
    end

    local query = self.query_override or self:view().query
    Task.run(_("Fetching mail…"), function()
        return Gmail.list{ query = query, max = 25 }
    end, function(result, err)
        if not result then
            if #self.messages == 0 then Task.error(err) else Task.notify(err) end
            return
        end
        self.messages = result.messages
        self.stale_age = nil
        Cache.set(self:cacheKey(), self.messages)
        self:refreshItems()
    end)
end

function MailList:switchView(index)
    self.view_index = index
    self.query_override = nil
    self.messages = {}
    self:refreshItems()
    self:load()
end

--- Applies a triage action, then re-renders from the mutated in-memory list.
function MailList:applyAction(label, work)
    Task.run(label, work, function(ok, err)
        if not ok then
            Task.error(err)
            return
        end
        Cache.set(self:cacheKey(), self.messages)
        self:refreshItems()
    end)
end

function MailList:removeMessage(message)
    for index, entry in ipairs(self.messages) do
        if entry.id == message.id then
            table.remove(self.messages, index)
            break
        end
    end
end

function MailList:actionsFor(message)
    local dialog
    local function action(label, work)
        return {
            text = label,
            align = "left",
            callback = function()
                UIManager:close(dialog)
                self:applyAction(label .. "…", work)
            end,
        }
    end

    local buttons = {
        { action(message.unread and _("Mark as read") or _("Mark as unread"), function()
            local add = message.unread and {} or { "UNREAD" }
            local remove = message.unread and { "UNREAD" } or {}
            local ok, err = Gmail.modify(message.id, add, remove)
            if ok then message.unread = not message.unread end
            return ok, err
        end) },
        { action(message.starred and _("Unstar") or _("Star"), function()
            local add = message.starred and {} or { "STARRED" }
            local remove = message.starred and { "STARRED" } or {}
            local ok, err = Gmail.modify(message.id, add, remove)
            if ok then message.starred = not message.starred end
            return ok, err
        end) },
        { action(_("Archive"), function()
            local ok, err = Gmail.modify(message.id, {}, { "INBOX" })
            if ok then self:removeMessage(message) end
            return ok, err
        end) },
        { {
            text = _("Move to trash"),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                UIManager:show(ConfirmBox:new{
                    text = T(_("Move to trash?\n\n%1"), Fmt.clip(message.subject, 80)),
                    ok_text = _("Trash"),
                    ok_callback = function()
                        self:applyAction(_("Trashing…"), function()
                            local ok, err = Gmail.trash(message.id)
                            if ok then self:removeMessage(message) end
                            return ok, err
                        end)
                    end,
                })
            end,
        } },
    }

    dialog = ButtonDialog:new{
        title = Fmt.clip(message.subject, 60),
        buttons = buttons,
        shrink_unneeded_width = true,
    }
    UIManager:show(dialog)
end

function MailList:openSearch()
    local input
    input = InputDialog:new{
        title = _("Search mail"),
        input = self.query_override or "",
        description = _("Uses Gmail search syntax, e.g. from:ada has:attachment newer_than:7d"),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(input) end },
            { text = _("Search"), is_enter_default = true, callback = function()
                local query = input:getInputText()
                UIManager:close(input)
                if query and query ~= "" then
                    self.query_override = query
                    self.messages = {}
                    self:refreshItems()
                    Task.run(_("Searching…"), function()
                        return Gmail.list{ query = query, max = 25 }
                    end, function(result, err)
                        if not result then Task.error(err) return end
                        self.messages = result.messages
                        self.menu:switchItemTable(T(_("Search: %1"), Fmt.clip(query, 30)), self:itemTable())
                    end)
                end
            end },
        }},
    }
    UIManager:show(input)
    input:onShowKeyboard()
end

function MailList:openNavMenu()
    local dialog
    local buttons = {}
    for index, view in ipairs(MailList.VIEWS) do
        buttons[#buttons + 1] = { {
            text = view.title,
            align = "left",
            callback = function()
                UIManager:close(dialog)
                self:switchView(index)
            end,
        } }
    end
    buttons[#buttons + 1] = { { text = _("Search mail"), align = "left",
        callback = function() UIManager:close(dialog) self:openSearch() end } }
    buttons[#buttons + 1] = { { text = _("Refresh"), align = "left",
        callback = function() UIManager:close(dialog) self:load(true) end } }
    buttons[#buttons + 1] = { { text = _("Calendar"), align = "left",
        callback = function() UIManager:close(dialog) self:close() self.hub.openAgenda() end } }
    buttons[#buttons + 1] = { { text = _("Settings"), align = "left",
        callback = function() UIManager:close(dialog) self.hub.openSettings() end } }

    dialog = ButtonDialog:new{ title = _("Mail"), buttons = buttons, shrink_unneeded_width = true }
    UIManager:show(dialog)
end

function MailList:close()
    if self.menu then
        UIManager:close(self.menu)
        self.menu = nil
    end
end

function MailList:show()
    self.menu = Menu:new{
        title = self:title(),
        item_table = self:itemTable(),
        is_borderless = true,
        is_popout = false,
        single_line = true,
        -- Leave room for the ZenOS bar that gets attached below.
        height = Navbar.bodyHeight(),
        title_bar_left_icon = "appbar.menu",
        onLeftButtonTap = function() self:openNavMenu() end,
        onMenuSelect = function(_menu, item)
            if item.message then
                -- The whole list goes in so the viewer can offer Previous/Next.
                MailView.show{
                    messages = self.messages,
                    index = item.index,
                    on_change = function(removed)
                        if removed then self:removeMessage(item.message) end
                        Cache.set(self:cacheKey(), self.messages)
                        self:refreshItems()
                    end,
                }
            end
            return true
        end,
        onMenuHold = function(_menu, item)
            if item.message then self:actionsFor(item.message) end
            return true
        end,
        close_callback = function() self:close() end,
    }
    SectionButton.attach(self.menu.title_bar, "calendar", function()
        self:close()
        self.hub.openAgenda("week")
    end)
    Navbar.attachToMenu(self.menu, function(tab_id)
        Navbar.navigate(function() self:close() end, tab_id)
    end)
    UIManager:show(self.menu)
    self:load()
    return self.menu
end

return MailList
