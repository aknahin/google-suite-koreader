--[[--
Account setup, status, and preferences.

Sign-in cannot happen on the device: Google's limited-input-device grant does
not cover Gmail or Calendar scopes. `tools/google_auth.py` does the ordinary
loopback flow on a computer and writes a token file, which is imported here.
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local PathChooser = require("ui/widget/pathchooser")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local T = require("ffi/util").template
local _ = require("gettext")

local Account = require("lib/account")
local Cache = require("lib/cache")
local Http = require("lib/http")
local Task = require("ui/task")

local Setup = {}

local INSTRUCTIONS = _([[Google does not allow e-readers to sign in directly: its device sign-in flow cannot grant access to Gmail or Calendar. Signing in is therefore done once on a computer.

1. In the Google Cloud console, create a project, enable the Gmail API and the Google Calendar API, and create an OAuth client of type "Desktop app". Download its JSON.

2. Set the OAuth consent screen to "In production". While it is set to "Testing", Google expires the sign-in after 7 days and you would have to repeat this every week. You will see an "unverified app" warning once; that is expected for a client you created yourself.

3. On the computer, run:

    python3 google_suite.koplugin/tools/google_auth.py --client-secrets client_secret.json

   A browser opens, you approve access, and the script writes google_token.json.

4. Copy google_token.json onto this device over USB, then choose "Import token file" below. Tick every permission checkbox on Google's consent page, or the matching feature will fail later.

The token file grants access to your mail. It is stored unencrypted on this device, so treat the device like a signed-in phone.]])

function Setup.importTokenFile(on_done)
    local chooser
    chooser = PathChooser:new{
        title = _("Select google_token.json"),
        select_directory = false,
        select_file = true,
        path = Device.home_dir or "/",
        onConfirm = function(path)
            Task.run(_("Checking credentials…"), function()
                return Account:importTokenFile(path)
            end, function(ok, err)
                if not ok then
                    Task.error(err or _("Could not import that token file."))
                    return
                end
                Cache.clearAll()
                UIManager:show(ConfirmBox:new{
                    text = T(_("Signed in as %1.\n\nDelete the token file from the device now?"),
                             Account:getEmail() or _("your account")),
                    ok_text = _("Delete"),
                    ok_callback = function() os.remove(path) end,
                })
                if on_done then on_done() end
            end)
        end,
    }
    UIManager:show(chooser)
end

function Setup.showInstructions()
    UIManager:show(TextViewer:new{
        title = _("Connecting a Google account"),
        text = INSTRUCTIONS,
        text_type = "file_content",
    })
end

--- Shown instead of the mail list when no account is connected yet.
function Setup.showOnboarding(on_done)
    local dialog
    dialog = ButtonDialog:new{
        title = _("Google Suite is not connected yet."),
        buttons = {
            { { text = _("How to connect an account"), align = "left",
                callback = function() UIManager:close(dialog) Setup.showInstructions() end } },
            { { text = _("Import token file"), align = "left",
                callback = function() UIManager:close(dialog) Setup.importTokenFile(on_done) end } },
            { { text = _("Cancel"), align = "left",
                callback = function() UIManager:close(dialog) end } },
        },
        shrink_unneeded_width = true,
    }
    UIManager:show(dialog)
end

function Setup.show(on_done)
    if not Account:isConfigured() then
        Setup.showOnboarding(on_done)
        return
    end

    local dialog
    local settings = Account:settings()

    local buttons = {
        { { text = T(_("Signed in as %1"), Account:getEmail() or _("(unknown)")),
            align = "left", enabled = false } },
        -- The agenda window is fixed at this week plus the next seven days, so
        -- there is no horizon to configure: see Gcal.windowKeys.
        { { text = settings:isFalse("grid_landscape")
                and _("Grid views: keep current rotation")
                or _("Grid views: switch to landscape"),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                settings:saveSetting("grid_landscape", settings:isFalse("grid_landscape"))
                settings:flush()
                Setup.show(on_done)
            end } },
        { { text = (settings:readSetting("week_start_dow") == 1)
                and _("Week starts on Sunday")
                or _("Week starts on Monday"),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                settings:saveSetting("week_start_dow",
                    settings:readSetting("week_start_dow") == 1 and 2 or 1)
                settings:flush()
                Setup.show(on_done)
            end } },
        { { text = _("Clear cached mail and events"), align = "left",
            callback = function()
                UIManager:close(dialog)
                Cache.clearAll()
                Task.notify(_("Cache cleared."))
            end } },
        { { text = Http.verify_certificates and _("TLS: verifying certificates")
                or _("TLS: NOT verifying certificates"),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                Http.verify_certificates = not Http.verify_certificates
                settings:saveSetting("tls_verify", Http.verify_certificates)
                settings:flush()
                if not Http.verify_certificates then
                    UIManager:show(InfoMessage:new{
                        text = _("Certificate checking is off. This is for diagnosing a TLS problem only — turn it back on afterwards."),
                        icon = "notice-warning",
                    })
                end
                Setup.show(on_done)
            end } },
        { { text = _("How to connect an account"), align = "left",
            callback = function() UIManager:close(dialog) Setup.showInstructions() end } },
        { { text = _("Re-import token file"), align = "left",
            callback = function() UIManager:close(dialog) Setup.importTokenFile(on_done) end } },
        { { text = _("Sign out"), align = "left",
            callback = function()
                UIManager:close(dialog)
                UIManager:show(ConfirmBox:new{
                    text = _("Sign out and remove the saved credentials from this device?"),
                    ok_text = _("Sign out"),
                    ok_callback = function()
                        Task.run(_("Signing out…"), function()
                            Account:signOut(true)
                            Cache.clearAll()
                            return true
                        end, function()
                            Task.notify(_("Signed out."))
                            if on_done then on_done() end
                        end)
                    end,
                })
            end } },
    }

    dialog = ButtonDialog:new{ title = _("Google Suite"), buttons = buttons, shrink_unneeded_width = true }
    UIManager:show(dialog)
end

--- Applies persisted preferences at plugin start.
function Setup.applyPreferences()
    local verify = Account:settings():readSetting("tls_verify")
    if verify ~= nil then Http.verify_certificates = verify end
end

return Setup
