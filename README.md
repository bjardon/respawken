# respawken

<p align="center">
  <img src="docs/app-icon.png" alt="Respawken" width="168" />
</p>

A tiny macOS menu bar app that shows how much Claude Code, Codex, Cursor, Notion AI, and
Antigravity usage you have left, and when each limit resets.

Native Swift/SwiftUI, no Dock icon, about 22 MB resident, 0% CPU when idle.

![panel](docs/panel.png)

The menu bar icon stacks one meter per account or product, top to bottom: your Claude
accounts, then Codex, Cursor, Notion AI, and Antigravity. Fill is usage. Color is severity,
green, amber, or red. A signed-out or failing product draws an empty outline, so a missing
reading never looks like a healthy zero. Settings → Menu bar icon has two other styles.
**Status** draws each meter as one solid severity color. **App Icon** draws a monotone ring
that dims as the fullest pinned window fills.

Click the icon, or press **⌃⌥U**, to open the panel. It opens on Overview, which shows the
same meters with labels. Click an Overview row to open that product's screen with all its
windows. Claude puts every account on one screen. The panel always reopens on Overview.

Each panel meter has a tick where usage would sit at a steady burn rate. The line under it
reads `below pace`, `on pace`, or `empties in …`. The menu bar icon only shows percent used.

The gear on the panel opens Settings. Add or edit Claude accounts there (a label plus a
config dir) and change or clear the shortcut. The defaults are Personal on `~/.claude` and
Work on `~/.claude-oxp`. Settings live in
`~/Library/Application Support/Respawken/settings.json`.

Each product pins one window onto the icon and Overview: Claude session, Notion 6-hour,
Codex 5-hour, Cursor Models, and Antigravity Gemini 5-hour. Change the pin in Settings.
If the pinned window has no reset time, Overview takes `resets in …` from the soonest
sibling window, or from the plan renewal for usage credits.

## Run it

```sh
./build.sh --run       # dist copy, for iterating
./build.sh --install   # /Applications, the copy banners and login open
```

`--run` builds `dist/Respawken.app` and launches it. `--install` builds the same bundle,
copies it to `/Applications/Respawken.app`, and launches that copy. Notification banners
and Launch at login open `/Applications`. If you only update `dist/`, you stay on the old
binary.

The first launch registers Respawken as a login item. Settings can turn that off. If login
still opens `dist/` after an install, toggle Launch at login off and on so macOS picks up
`/Applications`.

When a reading or layout looks wrong:

```sh
./build.sh && ./dist/Respawken.app/Contents/MacOS/Respawken --probe     # print live values
./dist/Respawken.app/Contents/MacOS/Respawken --preview /tmp/panel.png  # render the UI to a PNG
```

## Where the numbers come from

respawken reads the credentials each tool already stores on your Mac, so you never log in
again. It also stores its own preferences, notification bookkeeping, Claude polling
timestamps, and renewal metadata locally.

| Product | Source | Notes |
| --- | --- | --- |
| Codex | `~/.codex/auth.json` → `chatgpt.com/backend-api/wham/usage` | Refreshes expired access tokens via `auth.openai.com/oauth/token` and writes the new tokens back, so Codex keeps working. Plus accounts get a 5-hour session window and a weekly one. Weekly-only plans get just the weekly. If the API is unreachable or refresh fails, it reads the `rate_limits` block from the newest log in `~/.codex/sessions` or `archived_sessions`. |
| Cursor | `state.vscdb` → `cursor.com/api/usage-summary` | Reuses the bearer token Cursor.app already holds. No browser cookie decryption. Cursor bills monthly, so the reset is the end of the billing cycle. Cursor Models and Other Models are percent gates. On-demand, when enabled, is a dollar cap stored in cents. |
| Claude Code | Default `~/.claude` → Keychain `Claude Code-credentials`. A custom `CLAUDE_CONFIG_DIR` → `Claude Code-credentials-<sha256[:8]>` or `$dir/.credentials.json`. Both → `api.anthropic.com/api/oauth/usage` | One account per Settings entry. Access tokens expire after about 8 hours. respawken refreshes them via `platform.claude.com/v1/oauth/token` and writes the new tokens back, so Claude Code keeps working. The endpoint returns no email, so rows use your labels. Team extra budget is usage credits, read from `spend` with `extra_usage` as the legacy fallback. Fable is a weekly cap nested in `limits[]` (`weekly_scoped`, display name Fable), not a top-level `seven_day_*` key. |
| Notion AI | Notion.app Cookies + Keychain `Notion Safe Storage` → `app.notion.com/api/v3/getCreditRateLimitStatus`, plus `getAIUsageEligibilityV2` for credits | Decrypts the desktop app's `token_v2` session cookie, reading the key via `/usr/bin/security` to skip the Keychain prompt, same as Claude. Tracks the 6-hour and monthly AI allowance on Business and Enterprise, plus the Notion credits balance. These are Notion's private web APIs, not the public API, and Notion can change them without notice. |
| Antigravity | The running `agy` loopback server, else Keychain `gemini`/`antigravity` → `cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary` | Gemini and Claude/GPT each get a weekly and a 5-hour window, the same groups `/usage` shows. When `agy` is open, respawken asks its local language server, which needs no CSRF token and uses a self-signed loopback cert. Otherwise it reuses the OAuth session `agy` stored in the Keychain as a `go-keyring-base64` blob, read via `/usr/bin/security`. Access tokens last about an hour. respawken refreshes them and writes the new tokens back. |

respawken polls every product at once every 2 minutes, with a 12-second timeout each. A
slow or signed-out product never blocks the others. Polling speeds up to every 30 seconds
while a window sits between 90% and 98%, or a reset is less than 10 minutes away. A window
stuck at 99–100% with hours left stays on the 2-minute poll.

Claude has its own floor of 5 minutes per account. That floor also covers manual refreshes,
`--probe`, and `--preview`. Claude requests run one at a time across every Respawken
process, and renewal metadata is cached for 24 hours.

### Notifications

macOS asks for notification permission on first launch. If you allow it, respawken sends an
alert when:

- any active window reaches 98% used,
- a weekly or monthly window is on track to run out before it resets,
- a window resets. This uses the same timestamp as the `resets in …` countdown.

When several windows reset at the same moment, such as Cursor's billing cycle, you get one
alert per product.

Titles get one emoji and a bit of attitude: `🔥 Running on fumes`, `⏳ Ahead of pace`,
`✨ Fresh limits`. Bodies are one short sentence, like `Claude (Personal)'s session just hit 99%`
or `Codex's weekly is on track to empty in 2d`.

### Things I learned the hard way

**Cursor's state database is about 3 GB.** respawken opens it read-only with SQLite's
`immutable=1`, which skips locking and WAL recovery. A point lookup takes about 13 ms and
never touches the copy Cursor is writing.

**Claude's credentials go through `/usr/bin/security`, not `SecItemCopyMatching`.** Reading
that Keychain item in-process raises an authorization prompt and takes about 8 seconds.
macOS also ties the "Always Allow" grant to the binary's code hash, so every rebuild prompts
again. I tried signing with a real certificate and a hash-free designated requirement. It
didn't help.

Claude Code's Keychain item already trusts Apple's `security` tool, so shelling out to it
reads the same secret in about 20 ms with no prompt, on any build. respawken checks the
item's modification date first so it doesn't spawn a process on every poll.

**Claude access tokens expire after about 8 hours.** Before refresh existed, overnight polls
got 401s and the panel asked for a re-login every morning, even though the refresh token was
good for weeks. respawken now refreshes through Claude Code's public OAuth client
(`platform.claude.com/v1/oauth/token`) when the access token is expired or close to it. It
writes the new tokens back to the Keychain, so the CLI and the menu bar share one session.
Cloudflare on that host blocks non-CLI user agents, so the request sends the installed
`claude` version string as its User-Agent.

**A 429 keeps the last good reading.** It doesn't blank the product. Claude also pauses all
its accounts for at least 15 minutes after a 429 and doubles the wait on each repeat, up to
6 hours. A longer `Retry-After` wins. The cooldown survives restarts and is shared with
`--probe` and `--preview`. Its file holds only timing and renewal metadata, never
credentials. If respawken can't read that file, it pauses Claude requests rather than
risk another 429.

## Layout

```
Sources/Respawken/
  App.swift              MenuBarExtra + Settings window
  Store.swift            polling, concurrency, refresh cadence
  AppSettings.swift      persisted Claude accounts, language, shortcut
  HotKey.swift           global panel shortcut + MenuBarExtra toggle
  L10n.swift             English / Spanish UI catalog
  SettingsView.swift     Settings window UI
  LaunchAtLogin.swift    SMAppService register / unregister
  Notifications.swift    UserNotifications: 98% and scheduled resets
  Model.swift            UsageWindow / ProviderSnapshot, formatting
  MenuBarIcon.swift      menu bar icon styles
  PanelView.swift        the panel
  Probe.swift            --probe and --preview
  Providers/             one file per product
  Support/Sources.swift  Keychain, SQLite, JWT, HTTP, Chromium cookie decrypt, tolerant JSON accessors
```

Prior art: [CodexBar](https://github.com/steipete/CodexBar) supports about 29 products.
respawken covers five and tries to stay boring.
