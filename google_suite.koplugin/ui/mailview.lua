--[[--
A single message: HTML or plain text, triage buttons, and list navigation.

Two things worth knowing about the read-marking here. Gmail rejects a modify
payload whose label list is an empty JSON object, so `Gmail.modify` omits empty
sides — see `lib/gmail.lua`. And the mark-as-read call rides along inside the
same network task as the fetch rather than starting a second one, so there is one
spinner and no Trapper coroutine nested inside another.
--]]

local ConfirmBox = require("ui/widget/confirmbox")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local T = require("ffi/util").template
local _ = require("gettext")

local Account = require("lib/account")
local Cache = require("lib/cache")
local Fmt = require("lib/fmt")
local Gmail = require("lib/gmail")
local SectionButton = require("ui/sectionbutton")
local Task = require("ui/task")

local MailView = {}

local function bodyCacheKey(id)
    return "message_" .. id
end

local function preferHtml()
    return not Account:settings():isFalse("render_html")
end

--- The header block shown above the body, in the format the viewer will render.
local function header(message, as_html)
    local sender = message.from or ""
    if message.from_address and message.from_address ~= message.from then
        sender = sender .. " <" .. message.from_address .. ">"
    end
    local lines = { T(_("From: %1"), sender) }
    if message.to and message.to ~= "" then
        lines[#lines + 1] = T(_("To: %1"), message.to)
    end
    lines[#lines + 1] = T(_("Date: %1"), Fmt.dateTime(message.timestamp))
    if message.attachments and #message.attachments > 0 then
        lines[#lines + 1] = T(_("Attachments: %1"), table.concat(message.attachments, ", "))
    end

    if not as_html then
        return table.concat(lines, "\n") .. "\n\n"
    end
    local escaped = {}
    for _i, line in ipairs(lines) do
        escaped[#escaped + 1] = line:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    end
    return "<div style=\"font-size: 80%\">" .. table.concat(escaped, "<br/>") ..
           "</div><hr/>"
end

--- Renders as HTML only when there is HTML worth rendering.
local function useHtml(message)
    if not preferHtml() then return false end
    local html = message.html
    return html ~= nil and html:gsub("<[^>]*>", ""):gsub("%s", "") ~= ""
end

--[[--
Open a message.

@tparam table opts
    messages  (table)    the list being browsed, for Previous/Next
    index     (number)   position in that list
    on_change (function) called as on_change(removed) after anything that
                         alters the list
--]]
function MailView.show(opts)
    local messages, index, on_change = opts.messages, opts.index, opts.on_change
    local summary = messages[index]
    if not summary then return end

    local function openAt(new_index)
        if messages[new_index] then
            MailView.show{ messages = messages, index = new_index, on_change = on_change }
        end
    end

    local function present(message)
        local viewer
        local as_html = useHtml(message)

        local function act(label, work, removes)
            return {
                text = label,
                callback = function()
                    Task.run(label .. "…", work, function(ok, err)
                        if not ok then
                            Task.error(err)
                            return
                        end
                        UIManager:close(viewer)
                        if on_change then on_change(removes) end
                    end)
                end,
            }
        end

        local buttons = {
            {
                {
                    text = "◀ " .. _("Previous"),
                    enabled = messages[index - 1] ~= nil,
                    callback = function()
                        UIManager:close(viewer)
                        openAt(index - 1)
                    end,
                },
                act(_("Archive"), function()
                    local ok, err = Gmail.modify(message.id, nil, { "INBOX" })
                    if ok then summary.in_inbox = false end
                    return ok, err
                end, true),
                act(message.starred and _("Unstar") or _("Star"), function()
                    local add = message.starred and nil or { "STARRED" }
                    local remove = message.starred and { "STARRED" } or nil
                    local ok, err = Gmail.modify(message.id, add, remove)
                    if ok then
                        message.starred = not message.starred
                        summary.starred = message.starred
                    end
                    return ok, err
                end),
                {
                    text = _("Next") .. " ▶",
                    enabled = messages[index + 1] ~= nil,
                    callback = function()
                        UIManager:close(viewer)
                        openAt(index + 1)
                    end,
                },
            },
            {
                act(_("Mark unread"), function()
                    local ok, err = Gmail.modify(message.id, { "UNREAD" }, nil)
                    if ok then summary.unread = true end
                    return ok, err
                end),
                {
                    text = message.html and (as_html and _("As text") or _("As HTML"))
                        or _("As text"),
                    enabled = message.html ~= nil,
                    callback = function()
                        local settings = Account:settings()
                        settings:saveSetting("render_html", not preferHtml())
                        settings:flush()
                        UIManager:close(viewer)
                        present(message)
                    end,
                },
                {
                    text = _("Trash"),
                    callback = function()
                        UIManager:show(ConfirmBox:new{
                            text = _("Move this message to trash?"),
                            ok_text = _("Trash"),
                            ok_callback = function()
                                Task.run(_("Trashing…"), function()
                                    return Gmail.trash(message.id)
                                end, function(ok, err)
                                    if not ok then Task.error(err) return end
                                    Cache.delete(bodyCacheKey(message.id))
                                    UIManager:close(viewer)
                                    if on_change then on_change(true) end
                                end)
                            end,
                        })
                    end,
                },
                {
                    text = _("Close"),
                    callback = function() UIManager:close(viewer) end,
                },
            },
        }

        viewer = TextViewer:new{
            title = (message.subject and message.subject ~= "") and message.subject
                or _("(no subject)"),
            text = as_html and (header(message, true) .. message.html)
                or (header(message, false) .. (message.body or "")),
            text_format = as_html and "html" or nil,
            text_type = "file_content",
            buttons_table = buttons,
        }
        -- TextViewer names its title bar `titlebar`, not `title_bar`.
        SectionButton.attach(viewer.titlebar, "calendar", function()
            UIManager:close(viewer)
            require("ui/appview").openSection("calendar", "week")
        end)
        UIManager:show(viewer)
    end

    local cached = Cache.get(bodyCacheKey(summary.id))
    if cached then
        present(cached)
        -- Nothing is in flight, so this is a top-level task, not a nested one.
        if summary.unread then
            Task.run(_("Marking as read…"), function()
                return Gmail.modify(summary.id, nil, { "UNREAD" })
            end, function(ok, err)
                if not ok then
                    Task.error(err)
                    return
                end
                summary.unread = false
                if on_change then on_change(false) end
            end)
        end
        return
    end

    Task.run(_("Opening…"), function()
        local message, err = Gmail.get(summary.id)
        if not message then return nil, err end
        -- Marking read in the same task keeps it to one spinner, and surfaces
        -- the failure instead of swallowing it the way the old code did.
        if summary.unread then
            local ok, modify_err = Gmail.modify(summary.id, nil, { "UNREAD" })
            if ok then
                summary.unread = false
                message.marked_read = true
            else
                message.mark_read_error = modify_err
            end
        end
        return message
    end, function(message, err)
        if not message then
            Task.error(err)
            return
        end
        Cache.set(bodyCacheKey(summary.id), message)
        present(message)
        if message.mark_read_error then
            Task.error(T(_("Could not mark as read: %1"), message.mark_read_error))
        elseif message.marked_read and on_change then
            on_change(false)
        end
    end)
end

return MailView
