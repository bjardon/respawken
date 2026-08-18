# TODO

## Working

- [x] Menu bar item showing stacked meters, no Dock icon
- [x] Dropdown panel with per-window usage, plan, and reset countdown
- [x] **Overview + product drill-down** — panel opens on one meter per icon slot
      (the window that drives the menu bar); click a row for that product's full
      windows. Claude stacks every account on one product page. Reopens on Overview.
      Hover highlights Overview rows. Tabs were tried and dropped.
- [x] **Codex** — live usage, plan, weekly window, reset countdown
- [x] **Codex** — offline fallback to the last session log when the API is unreachable
- [x] **Codex** — OAuth auto-refresh — expired access tokens refresh without re-login
- [x] **Codex** — 401 / expired-token fallback note (not the generic "API unreachable")
- [x] **Cursor** — live usage, plan, billing-cycle reset, on-demand spend
- [x] **Cursor** — labels match Plan & Usage (Cursor Models / Other Models); note uses
      percent gates, not the dollar `used`/`limit` ledger (that was a false "on bonus")
- [x] **Claude Code** — live session and weekly windows, plan, reset countdown
- [x] **Claude Code** — Personal + Work accounts as separate top-level rows / meters
- [x] An idle Claude session window reads "not started" rather than a bare 0%
- [x] Signed-out and error states that read as "no data", not "0% used"
- [x] Auto-refresh every 2 minutes (30s while a window is still burning 90–98%, or a
      reset is within 10 minutes) + manual refresh; countdowns tick every minute
- [x] Exhaustion notification fires once per window until usage drops back under 90%
      (Claude's jittery `resets_at` no longer re-triggers "on fumes")
- [x] **Language** — Settings picker for English / Español; panel, Settings, and
      notifications switch instantly from an in-app catalog
- [x] `--probe` (print live values) and `--preview` (render the UI to a PNG)
- [x] `build.sh` producing a signed `Respawken.app`
- [x] No Keychain password prompt, on any build — Claude's secret is read via `/usr/bin/security`
- [x] Claude OAuth auto-refresh — expired access tokens refresh overnight without re-login
- [x] Transient failures (429) keep the last good reading instead of blanking the panel
- [x] Native Notification Center alerts at ≥98% usage and when a window's reset time fires
- [x] **Claude accounts settings** — gear opens a Settings window; add / rename / remove
      accounts with label + config dir; persisted to Application Support; panel and
      menu bar rebuild from that list. Codex and Cursor stay single-source.
- [x] **Notion AI** — rolling 6-hour + monthly usage allowance from Notion.app session;
      Notion credits balance / monthly credits window via private `/api/v3` endpoints
- [x] **App icon** — cooldown-ring + token core; `Resources/AppIcon.icon` (Icon Composer
      stack for macOS 26) + legacy `Assets.xcassets`; `build.sh` compiles `Assets.car` via
      `actool`, sets `CFBundleIconName`, and ships a full `.icns`. Bundle id bumped to
      `com.bjardon.respawken.app` so NC drops the blank icon cached from pre-icon builds.
      Settings → Send Test Notification (and `--test-notification`) to verify the banner icon.
- [x] Notification copy — wry titles with one emoji each + composed sentence bodies
      (`🔥 Running on fumes` / `✨ Fresh limits` / `👋 Still here`)
- [x] Launch at login — first launch registers via `SMAppService`; Settings toggle can undo it;
      later launches don't re-register if it was turned off

## Known gaps

- Claude shows no account email — the usage endpoint doesn't return one, unlike Codex and Cursor.
  Multi-account rows use configured labels (Personal / Work) instead.
- Claude's Opus/Sonnet/Cowork weekly windows are parsed but all came back `null` on a Team plan,
  so those rows are still unproven.
- Settings has no reorder UI yet — accounts appear in list order; add/remove works.
- Notion AI uses undocumented `app.notion.com/api/v3` endpoints authenticated with the
  desktop session cookie; Notion can change them without notice. Multi-workspace accounts
  currently pick the first Business/Enterprise space Notion returns.

## Not done yet

- [ ] Remember the last good reading across restarts, so the panel isn't empty on launch
- [ ] Reorder Claude accounts in Settings (drag or up/down)
- [ ] Hover states on the other panel controls (back, gear, refresh, Quit)
- [ ] Keyboard shortcut to toggle the panel
- [ ] Make the Overview a bit more compact
- [ ] Richer product drill-downs — Codex reset details, Claude's unproven
      Opus/Sonnet/Cowork weekly windows, other on-demand extras
- [ ] **Google Antigravity** — usage in the menu bar / Overview like the other providers
