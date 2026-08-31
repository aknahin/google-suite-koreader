local _ = require("gettext")
return {
    name = "google_suite",
    fullname = _("Google Suite"),
    -- Kept in step with the git tag the release was cut from.
    version = "1.0.0",
    description = _([[Read and triage Gmail and view your Google Calendar agenda from KOReader.

Sign-in is done once on a computer with the bundled helper script; the resulting token file is imported here.]]),
}
