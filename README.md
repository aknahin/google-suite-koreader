# Google Suite for KOReader

Gmail and Google Calendar inside KOReader, designed for e-ink and for
[ZenOS](https://github.com/xZenLabs/zen-os) — it registers itself as a launchable
plugin, so it can be added as a navbar tab and contribute a Home-page widget.

- **Mail** — Inbox / Unread / Starred / Sent / Drafts / All mail, Gmail search
  syntax, Previous and Next to walk the list from inside a message, and triage:
  mark read or unread, star, archive, trash. HTML mail is normalised before it
  is rendered, so modern mail lays out on a small screen instead of overflowing
  it; one tap switches to plain text.
- **Writing** — compose, reply, reply-all, forward, and save as a draft.
  Messages go out as plain text: a Kindle keyboard is not somewhere to write
  markup, and `text/plain` renders correctly everywhere. Opening something from
  Drafts reopens it in the composer rather than the reader.
- **Calendar** — read-only, in three views: an agenda of event cards grouped by
  day, a week grid, and a month grid. The grids switch to landscape, because
  seven columns on a 6" screen in portrait leaves about 150px each. The agenda
  covers a fixed window — this week, plus the next seven days.
- **Offline first** — every view paints from a disk cache before it touches the
  network, and cached events never expire, so the calendar still opens with Wi-Fi
  off. Anything older than the last successful fetch is labelled *cached*, not
  hidden.
- **One tap between the two** — every mail page carries a calendar button beside
  its close icon, and every calendar page a mail button, so switching never goes
  through a menu.

Creating calendar events is deliberately out of scope for now.

## Why sign-in happens on a computer

Google's OAuth grant for limited-input devices (the "enter this code on your
phone" flow) [only supports](https://developers.google.com/identity/protocols/oauth2/limited-input-device)
`openid`, `email`, `profile`, two Drive scopes and YouTube. Gmail and Calendar
are not on that list, so an e-reader cannot complete a sign-in on its own.

Instead, `tools/google_auth.py` runs the ordinary loopback flow on a computer and
writes a token file that you import on the device once.

## Setup

Roughly 20 minutes, once. Three of the five stages happen on a computer, because
Google will not let an e-reader sign in on its own (see above).

You will need:

- a computer with **Python 3.8 or newer** and a browser,
- a **USB cable** for the Kindle,
- **KOReader already installed** on the device.

---

### Stage 1 — Create your own Google OAuth client

Gmail scopes are *restricted*, so a shared published client would need a CASA
security assessment. This plugin therefore ships no client credentials: you
create a client for yourself, and it talks only to your own account.

**1.1 Create a project.**
Go to <https://console.cloud.google.com/>, open the project picker in the top
bar, and choose **New project**. Name it anything (`koreader-mail` is fine) and
create it. Make sure the project picker now shows that project — everything
below applies to the selected project.

**1.2 Enable the two APIs.**
Go to *APIs & Services > Library*, search for **Gmail API**, open it, and press
**Enable**. Then do the same for **Google Calendar API**. Both must be enabled
or the plugin gets a `403 accessNotConfigured` on its first request.

**1.3 Configure the consent screen.**
Open *APIs & Services > OAuth consent screen* (recent consoles call this
**Google Auth Platform**). Choose **External** as the user type, then fill in:

- App name — anything, e.g. `KOReader Google Suite`.
- User support email — your own address.
- Developer contact email — your own address.

Save and continue.

**1.4 Declare the scopes.**
On the *Scopes* step, press **Add or remove scopes** and add these four:

```
https://www.googleapis.com/auth/gmail.readonly
https://www.googleapis.com/auth/gmail.modify
https://www.googleapis.com/auth/calendar.readonly
openid
```

Gmail's two scopes are flagged *restricted* — expected, and fine for a client
only you will ever use. Save and continue.

**1.5 Set the publishing status to "In production".**
On the consent screen's summary page, press **Publish app** and confirm.

> **Do not leave it in "Testing".** In Testing, Google expires the refresh token
> after **7 days**, and you would have to redo Stages 2–4 every week. Publishing
> an unverified app instead costs you one "Google hasn't verified this app"
> warning at sign-in time, which you click through once.
>
> Google may show a note about verification being required for restricted
> scopes. You can ignore it: unverified apps still work for the account that
> owns the project, up to a 100-user cap you will never approach.

**1.6 Create the client and download its JSON.**
Go to *APIs & Services > Credentials > Create credentials > OAuth client ID*.
Set **Application type** to **Desktop app**, name it, and create it. Press
**Download JSON** and save the file as `client_secret.json` next to this repo.

The type matters: a *Desktop app* client is the one allowed to use the loopback
redirect (`http://127.0.0.1:<port>`) that the helper script listens on.

---

### Stage 2 — Authorize on the computer

**2.1 Run the helper.** From the repository root:

```sh
python3 google_suite.koplugin/tools/google_auth.py --client-secrets client_secret.json
```

Standard library only — nothing to `pip install`. It prints a URL and opens your
browser. (On a headless machine, add `--no-browser` and open the URL yourself.)

**2.2 Approve access.** In the browser:

- Pick the Google account whose mail you want on the Kindle.
- You will see **"Google hasn't verified this app"**. Press **Advanced**, then
  **Go to <your app name> (unsafe)**. This is your own app; the warning only
  means you have not submitted it for Google's review.
- **Tick every permission checkbox** on the consent page, then press **Continue**.
  If you leave one unticked, that scope is silently dropped and the matching
  feature fails later with a `403 insufficient permissions`.

The browser tab shows "Signed in", and the terminal prints:

```
Wrote google_token.json for you@example.com.
```

**2.3 Confirm what you got.** `google_token.json` now sits in the current
directory with permissions `600`. It contains your client id, client secret and
a refresh token. **That file is a key to your mailbox** — handle it like a
password for the rest of this process.

If the script exits with *"Google did not return a refresh token"*, you have
authorized this client before. Remove its access at
<https://myaccount.google.com/permissions> and run it again.

---

### Stage 3 — Install the plugin on the Kindle

**3.1 Connect the Kindle over USB** and wait for it to mount as a drive.

**3.2 Copy the plugin folder.** Copy the whole `google_suite.koplugin` directory
to `koreader/plugins/` on that drive, so you end up with:

```
<Kindle drive>/koreader/plugins/google_suite.koplugin/main.lua
```

On the device itself that path is `/mnt/base-us/koreader/plugins/` (older
firmware: `/mnt/us/koreader/plugins/`) — the same place, seen from the other
side of the cable. Copy the **folder**, not its contents, and keep the
`.koplugin` suffix; KOReader only scans directories whose names end in it.

On macOS:

```sh
cp -R google_suite.koplugin /Volumes/Kindle/koreader/plugins/
```

**3.3 Copy the token file** to somewhere you can find on the device — the drive
root is easiest:

```sh
cp google_token.json /Volumes/Kindle/
```

**3.4 Eject the Kindle properly** and restart KOReader (exit and reopen it, or
restart the device).

Other devices, for reference:

| Device | Plugins directory |
| --- | --- |
| Kindle | `/mnt/base-us/koreader/plugins/` |
| Kobo | `/mnt/onboard/.adds/koreader/plugins/` |
| PocketBook | `/mnt/ext1/applications/koreader/plugins/` |
| Android | `sdcard/koreader/plugins/` |
| Desktop | `koreader/plugins/` |

---

### Stage 4 — Import the token on the device

**4.1 Check the plugin loaded.** In KOReader, open the top menu and look under
*Tools* for **Google Suite**. If it is missing, go to *Tools > More tools >
Plugin management*, enable **Google Suite**, and restart KOReader.

**4.2 Turn Wi-Fi on**, or let KOReader prompt you — the plugin asks for the
network itself the first time it needs it.

**4.3 Open *Tools > Google Suite*.** Because no account is connected yet, it
offers **How to connect an account** and **Import token file**.

**4.4 Choose "Import token file"**, browse to `google_token.json` where you put
it in step 3.3, and select it.

The plugin immediately exchanges the refresh token to prove the credentials work.
On success it shows *"Signed in as you@example.com"* and offers to delete the
token file from the device — **say yes**. It has already copied what it needs
into KOReader's settings.

**4.5 Delete the copy on your computer too**, or move it into a password
manager. It is a standing credential, not a one-time code.

---

### Stage 5 — Use it, and add it as a ZenOS tab

**5.1 First run.** The plugin opens on the Inbox and fetches 25 messages. Tap a
row to read it, then use **◀ Previous** / **Next ▶** to move through the list
without going back. Opening a message marks it read. **As text** / **As HTML**
switches how the body is rendered and remembers your choice. Long-press a row in
the list for Archive / Star / Mark unread / Trash. The
icon at the top-left of the title bar opens the section menu — Unread, Starred,
All mail, Search, Refresh, **Calendar**, and Settings.

**5.2 Calendar views.** Switch to Calendar; its title-bar menu holds the view
switcher — **List**, **Week**, **Month** — plus **Today**, **Refresh** and
**Choose calendars**. The chosen view is remembered.

In a grid view: tap a day to see its events, swipe left/right (or press the page
keys) to move a week or month at a time. Grids switch the screen to landscape and
put your orientation back when you leave; rotating by hand while a grid is open
re-lays it out rather than fighting you. Turn the auto-rotation off under
*Settings > Grid views*.

By default every calendar visible in Google Calendar is included. **Choose
calendars** narrows that — worth doing if you have many, though all of them are
fetched in a single batched request either way.

**5.3 Add the navbar tab** (needs [ZenOS](https://github.com/xZenLabs/zen-os)):

> *Zen Settings > Navbar > Tabs > Add > Plugin Menu > Google Suite*

Give it a label and an icon if you like. It can also be set as the default tab.

**5.4 Add the Home widget** (optional): *Zen Settings > Home > Widgets*, enable
**Google Suite**. Two boxes side by side — unread count, and the next event's
time and title — drawn purely from the cache so the Home page never waits on the
radio. The cache it reads is refreshed by any calendar view, so it stays current
whether you use the agenda or the grids. Tapping a box opens what it is showing:
the left one your unread mail, the right one the agenda.

**5.4a The ZenOS navbar**: plugin pages carry a navigation bar at the foot,
built from ZenOS's own tab configuration — same tabs, same order, same height —
with every tap handed back to ZenOS.

It has to be our own copy rather than ZenOS's. `UIManager:sendEvent` gives an
event to the topmost widget and then only to widgets flagged `is_always_active`,
so simply leaving a gap for the real bar underneath produces one that is visible
and completely dead. The bar does not highlight an active tab: none of those
tabs is what is on screen while this plugin is open.

**5.5 Bind a gesture** (optional): *Tools > Gestures* — the plugin registers a
**Google Suite** action you can attach to any gesture or key.

---

### Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| "Google Suite" missing from *Tools* | Wrong path or folder name. Confirm `.../koreader/plugins/google_suite.koplugin/main.lua` exists, then enable it in *Plugin management* and restart. |
| *"Google rejected the saved sign-in"* | The refresh token died — usually the consent screen is still in **Testing** (7-day expiry), or access was revoked. Fix Stage 1.5, then redo Stages 2 and 4. |
| `403` mentioning *accessNotConfigured* | Gmail API or Calendar API not enabled on the project (Stage 1.2). |
| `403` mentioning *insufficient permissions* | A permission checkbox was left unticked at Stage 2.2. Revoke at <https://myaccount.google.com/permissions> and redo Stage 2. |
| *"Network error. Check the Wi-Fi connection."* | Wi-Fi is off or asleep. Also appears if the TLS handshake is rejected — see the next row. |
| Every request fails, but Wi-Fi works | Possibly a certificate problem. In *Settings*, toggle **TLS** off to confirm that is the cause, then report it — and turn verification back on. Do not leave it off. |
| Calendar shows the wrong times | The device's timezone is wrong. Fix it in KOReader's time settings; the plugin renders in device-local time. |
| Mail list is stale | The list paints from cache first. Title-bar menu > **Refresh**, or *Settings > Clear cached mail and events*. |
| Month grid is cramped | You are in portrait with auto-rotation off. Turn on *Settings > Grid views: switch to landscape*, or rotate the device. |
| Week starts on the wrong day | *Settings > Week starts on* toggles Monday/Sunday. |
| Message body shows CSS or stylesheet text | Fixed — `<style>`, `<script>` and `<head>` are stripped before rendering. If you still see it, the mail nests those tags unusually; switch to **As HTML**. |
| Images missing in HTML mail | Deliberate. The renderer cannot fetch remote images, so `<img>` is stripped rather than left as broken-image boxes. |

## Security notes

- The refresh token is stored **unencrypted** in KOReader's settings directory.
  Anyone with the device has your mailbox — treat it like a signed-in phone.
- KOReader does not configure LuaSec, so its own HTTP calls do not verify TLS
  certificates. This plugin passes explicit SSL parameters and ships Google's
  root bundle (`data/roots.pem`, from <https://pki.goog/roots.pem>), so its
  traffic is verified. The toggle in Settings exists only to diagnose a TLS
  problem; leave it on.
- Sign-out revokes the token with Google and clears the local cache.

## Development

```sh
luajit spec/run.lua
```

`spec/harness.lua` stubs KOReader so the pure logic runs on a desktop: MIME and
RFC 2047 decoding, RFC 3339 parsing, the batch protocol, query building, the
calendar grid's date arithmetic, and the tap-to-day-cell geometry. It also asserts
the plugin still satisfies the ZenOS launcher contract in
`zen-os/modules/menu/app_launcher/plugin_scan.lua`, which is what makes it
eligible to be a navbar tab.

Two notes for anyone touching `lib/batch.lua`: Google picks a **fresh multipart
boundary per response** and prefixes the body with a **CRLF before the first
delimiter**. A parser anchored at position 1 looks correct against a hand-written
fixture and fails against the real API — the test fixture carries that leading
CRLF deliberately.

Layout:

```
google_suite.koplugin/
  main.lua          plugin entry, main-menu item, dispatcher action, ZenOS hooks
  lib/http.lua      JSON over HTTPS with certificate verification
  lib/account.lua   token storage, refresh, authorized requests
  lib/batch.lua     Google's multipart batch protocol, shared by both APIs
  lib/gmail.lua     list (batched metadata), read, triage, send and drafts
  lib/compose.lua   builds the RFC 2822 messages Gmail's raw field takes
  lib/gcal.lua      calendars, agenda and grid ranges; timezone-safe date math
  lib/mimeutil.lua  base64url, quoted-printable, RFC 2047, HTML sanitising
  lib/cache.lua     disk cache
  lib/icons.lua     the mail and calendar SVGs KOReader's icon set lacks
  lib/zenos.lua     the ZenOS globals: navbar height, home-item registration
  ui/calendargrid   the month/week grid widget, with rotation handling
  ui/eventlist      the paged list of event cards, shared by agenda and day view
  ui/compose        the composer: new, reply, forward, edit draft
  ui/navbar         our own copy of the ZenOS tab bar, drawn inside the page
  ui/sectionbutton  the mail/calendar button placed beside a title bar's close
  ui/               menus, message view, agenda, setup, ZenOS home widget
  icons/            plugin-owned SVGs, loaded by path rather than by name
  tools/            the computer-side sign-in helper
```
