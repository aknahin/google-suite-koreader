--[[--
Shared constants: endpoints, OAuth scopes, storage keys.
--]]
return {
    TOKEN_URL     = "https://oauth2.googleapis.com/token",
    REVOKE_URL    = "https://oauth2.googleapis.com/revoke",
    GMAIL_API     = "https://gmail.googleapis.com/gmail/v1",
    CALENDAR_API  = "https://www.googleapis.com/calendar/v3",
    USERINFO_URL  = "https://openidconnect.googleapis.com/v1/userinfo",

    -- Kept in sync with tools/google_auth.py.
    SCOPES = {
        "openid",
        "email",
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/gmail.modify",
        "https://www.googleapis.com/auth/calendar.readonly",
    },

    SETTINGS_FILE = "google_suite_settings",
    CACHE_DIR     = "google_suite",
}
