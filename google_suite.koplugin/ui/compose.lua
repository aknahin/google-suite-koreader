--[[--
Writing a message: new, reply, reply-all, forward, and editing a draft.

One `MultiInputDialog` carries the whole thing — To, Cc, Subject, Body — rather
than walking the user through a wizard of one-field prompts. Its fields are
plain `InputText`s, so the body grows with what is typed rather than scrolling;
that suits the short replies a device with this keyboard is actually used for,
and a long-form editor would be the wrong thing to optimise for here.

Sending never happens on the UI thread's own time: every call goes through
`ui/task.lua`, the same as every other network round trip in the plugin.
--]]

local MultiInputDialog = require("ui/widget/multiinputdialog")
local ConfirmBox = require("ui/widget/confirmbox")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local Account = require("lib/account")
local Compose = require("lib/compose")
local Gmail = require("lib/gmail")
local Task = require("ui/task")

local ComposeView = {}

--- Enough of an address to be worth sending to. Gmail does the real validation;
--- this only catches the empty and the obviously unfinished.
local function looksAddressable(text)
    return type(text) == "string" and text:find("@") ~= nil
end

local function fieldsFrom(dialog)
    local values = dialog:getFields()
    return {
        to      = values[1] or "",
        cc      = values[2] or "",
        subject = values[3] or "",
        body    = values[4] or "",
    }
end

--- The message to hand Gmail, with our own address on the From line.
local function rawFor(fields, context)
    return Compose.build{
        from        = Account:getEmail(),
        to          = fields.to,
        cc          = fields.cc,
        subject     = fields.subject,
        body        = fields.body,
        in_reply_to = context.in_reply_to,
        references  = context.references,
    }
end

--[[--
Opens the composer.

@tparam table opts
    title       (string)   what the dialog calls itself
    fields      (table)    prefilled to/cc/subject/body
    thread_id   (string)   keeps a reply in its conversation
    in_reply_to, references (string) threading headers
    draft_id    (string)   editing an existing draft rather than making one
    on_sent     (function) called after a successful send or draft save
--]]
function ComposeView.open(opts)
    opts = opts or {}
    local fields = opts.fields or {}
    local context = {
        thread_id   = opts.thread_id,
        in_reply_to = opts.in_reply_to,
        references  = opts.references,
        draft_id    = opts.draft_id,
    }

    local dialog
    local function close()
        UIManager:close(dialog)
        dialog = nil
    end

    local function send()
        local values = fieldsFrom(dialog)
        if not looksAddressable(values.to) then
            Task.notify(_("Add someone to send this to."))
            return
        end
        local function dispatch()
            close()
            Task.run(_("Sending…"), function()
                -- A draft that has been stored is sent through the drafts
                -- endpoint, which also clears it out of Drafts; sending the
                -- raw message instead would leave the draft sitting there.
                if context.draft_id then
                    local saved, save_err = Gmail.saveDraft(
                        rawFor(values, context), context.thread_id, context.draft_id)
                    if not saved then return nil, save_err end
                    return Gmail.sendDraft(context.draft_id)
                end
                return Gmail.send(rawFor(values, context), context.thread_id)
            end, function(sent, err)
                if not sent then return Task.error(err) end
                Task.notify(_("Sent."))
                if opts.on_sent then opts.on_sent() end
            end)
        end

        if values.subject:gsub("%s", "") == "" then
            UIManager:show(ConfirmBox:new{
                text = _("Send without a subject?"),
                ok_text = _("Send"),
                ok_callback = dispatch,
            })
            return
        end
        dispatch()
    end

    local function saveDraft()
        local values = fieldsFrom(dialog)
        close()
        Task.run(_("Saving draft…"), function()
            return Gmail.saveDraft(rawFor(values, context), context.thread_id,
                                   context.draft_id)
        end, function(saved, err)
            if not saved then return Task.error(err) end
            Task.notify(_("Draft saved."))
            if opts.on_sent then opts.on_sent() end
        end)
    end

    local function discard()
        -- Only worth asking about if there is something to lose.
        local values = fieldsFrom(dialog)
        local touched = values.to ~= (fields.to or "")
            or values.cc ~= (fields.cc or "")
            or values.subject ~= (fields.subject or "")
            or values.body ~= (fields.body or "")
        if not touched then return close() end
        UIManager:show(ConfirmBox:new{
            text = _("Discard this message?"),
            ok_text = _("Discard"),
            ok_callback = close,
        })
    end

    dialog = MultiInputDialog:new{
        title = opts.title or _("New message"),
        fields = {
            { description = _("To"), text = fields.to or "", hint = _("name@example.com") },
            { description = _("Cc"), text = fields.cc or "", hint = _("optional") },
            { description = _("Subject"), text = fields.subject or "", hint = _("Subject") },
            {
                description = _("Message"),
                text = fields.body or "",
                hint = _("Write your message"),
                allow_newline = true,
            },
        },
        buttons = {
            {
                { text = _("Cancel"), id = "close", callback = discard },
                { text = _("Save draft"), callback = saveDraft },
                { text = _("Send"), is_enter_default = true, callback = send },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
    return dialog
end

-- ------------------------------------------------------------- entry points ---

function ComposeView.newMessage(on_sent)
    return ComposeView.open{ title = _("New message"), on_sent = on_sent }
end

--- @tparam boolean all reply to everyone on the message, not just its sender
function ComposeView.reply(message, all, on_sent)
    local fields = Compose.reply(message, {
        all = all, self_address = Account:getEmail(),
    })
    return ComposeView.open{
        title       = all and _("Reply all") or _("Reply"),
        fields      = fields,
        thread_id   = message.thread_id,
        in_reply_to = fields.in_reply_to,
        references  = fields.references,
        on_sent     = on_sent,
    }
end

function ComposeView.forward(message, on_sent)
    return ComposeView.open{
        title   = _("Forward"),
        fields  = Compose.forward(message),
        on_sent = on_sent,
    }
end

--[[--
Reopens a draft for editing.

The Drafts view lists messages like every other view, so the draft that wraps
this message has to be looked up before it can be replaced rather than
duplicated. If that lookup fails the message still opens — as a new one, which
leaves the original draft alone rather than risking clobbering it.
--]]
function ComposeView.editDraft(message, on_sent)
    Task.run(_("Opening draft…"), function()
        return Gmail.draftIdForMessage(message.id) or false
    end, function(draft_id, err)
        if err then Task.notify(err) end
        ComposeView.open{
            title     = _("Draft"),
            fields    = {
                to      = message.to or "",
                cc      = message.cc or "",
                subject = message.subject or "",
                body    = message.body or "",
            },
            thread_id = message.thread_id,
            draft_id  = draft_id or nil,
            on_sent   = on_sent,
        }
    end)
end

return ComposeView
