# TODO

## Working

- [x] Claude pace uses reported usage and reset times even when `is_active` is false.
- [x] Claude polls each account at most every 5 minutes. The app, manual refreshes, probes,
      and previews share one persistent 429 cooldown. It honors `Retry-After`, waits longer
      after repeated failures, and caches renewal metadata for 24 hours.
- [x] Every product screen resizes the native panel to fit. Going back to Overview restores
      its height with no empty margin.
- [x] Menu bar images are reused when nothing changed. Notion allowance and credits load
      in parallel. Polling frequency is unchanged. Memory and energy gains aren't measured.
- [x] Codex log fallback reads stay bounded while the log grows and handle UTF-8 characters
      split across reads.
- [x] Panel PNG exports leave out the AppKit opening watcher, which otherwise makes the
      renderer draw a warning overlay. The live panel keeps it for opening and sizing.
- [x] Menu bar icon with stacked meters, no Dock icon
- [x] Panel with usage, plan, and reset countdown for each window
- [x] **Overview and product screens.** The panel opens on Overview, one meter per icon
      slot, each showing the pinned window. Click an Overview row for that product's
      screen. Claude puts every account on one screen. The panel reopens on Overview.
      Hover highlights Overview rows. I tried tabs and dropped them.
- [x] **Codex.** Live usage, plan, 5-hour session and weekly windows, reset countdown.
      Banked reset credits from `rate_limit_reset_credits` when `available_count` > 0.
- [x] **Codex.** Falls back to the newest session log in `sessions` or `archived_sessions`
      when the API is unreachable.
- [x] **Codex.** Expired access tokens refresh through OAuth, no re-login.
- [x] **Codex.** A 401 or expired token gets its own note instead of the generic "API unreachable".
- [x] **Cursor.** Live usage, plan, billing-cycle reset, on-demand spend.
- [x] **Cursor.** Labels match Plan & Usage: Cursor Models and Other Models. The note uses
      the percent gates. The dollar `used`/`limit` ledger produced a false "on bonus".
- [x] **Claude Code.** Live session and weekly windows, plan, reset countdown.
- [x] **Claude Code.** Personal and Work each get their own Overview row and meter.
- [x] An idle Claude session window reads "not started" instead of a bare 0%.
- [x] Signed-out and error states read as "no data", not "0% used".
- [x] Refresh every 2 minutes, or every 30s while a window sits at 90–98% or a reset is
      under 10 minutes away. Manual refresh too. Countdowns tick every minute.
- [x] The "on fumes" notification fires once per window until usage drops below 90%.
      Claude's jittery `resets_at` no longer re-triggers it.
- [x] **Language.** Settings picks English or Español. The panel, Settings, and
      notifications switch instantly from an in-app catalog.
- [x] `--probe` prints live values and `--preview` renders the UI to a PNG.
- [x] `build.sh` produces a signed `Respawken.app`.
- [x] No Keychain password prompt on any build. Claude's secret comes from `/usr/bin/security`.
- [x] Claude OAuth refresh. Expired access tokens refresh overnight without re-login.
- [x] A 429 keeps the last good reading instead of blanking the panel.
- [x] Notification Center alerts at 98% usage, when a long window is on track to run out
      before its reset, and when a window resets.
- [x] **Claude accounts in Settings.** The gear opens Settings. Add, rename, or remove
      accounts with a label and config dir. The list persists to Application Support,
      and the panel and menu bar icon rebuild from it. Codex and Cursor have one source each.
- [x] **Notion AI.** The 6-hour and monthly allowance from the Notion.app session, plus the
      Notion credits balance and monthly credits window, from private `/api/v3` endpoints.
- [x] **Google Antigravity.** Gemini and Claude/GPT weekly and 5-hour windows, from `agy`'s
      OAuth session in the Keychain or the running CLI's local `/usage` server.
- [x] **App icon.** A cooldown ring around a token core. `Resources/AppIcon.icon` is the
      Icon Composer stack for macOS 26, with a legacy `Assets.xcassets`. `build.sh` compiles
      `Assets.car` via `actool`, sets `CFBundleIconName`, and ships a full `.icns`. The
      bundle id moved to `com.bjardon.respawken.app` so Notification Center drops the blank
      icon it cached from pre-icon builds. Settings → Send Test Notification, or
      `--test-notification`, checks the banner icon.
- [x] Notification copy. Each title gets one emoji and some attitude (`🔥 Running on fumes`,
      `⏳ Ahead of pace`, `✨ Fresh limits`, `👋 Still here`). Each body is one sentence.
- [x] Launch at login. The first launch registers via `SMAppService`. The Settings toggle
      undoes it, and later launches respect that.
- [x] **Keyboard shortcut.** A global hotkey toggles the panel, ⌃⌥U by default. Change or
      clear it in Settings → Keyboard. No Accessibility permission needed.
- [x] **Renewal date.** Product screens show a `Renews:` row for the paid plan, separate
      from any window's reset. Claude uses `subscription_created_at`, Codex the ChatGPT
      id-token period, Cursor and Notion their billing-cycle end.
- [x] **Claude usage credits.** Extra budget from `/api/oauth/usage`, read from `spend`
      with `extra_usage` as the legacy fallback. When the org has a positive cap, the
      product screen shows a meter and `$used / $limit`. A `$0` limit only gets a note.
- [x] **Claude Fable.** A weekly cap nested in `/api/oauth/usage` `limits[]`
      (`weekly_scoped`, display name Fable). You can pin it.
- [x] Dropped **Now burning**. Claude and Notion pin session and 6-hour again. Old
      `now_burning` settings fall back to those.
- [x] **Pace.** Every window with a duration and a reset projects its average burn for
      the cycle. Panel meters show a tick for expected usage plus `below pace`, `on pace`,
      or `empties in …`. A weekly or monthly window that runs ahead sends one
      `⏳ Ahead of pace` notification per cycle. Session, 6-hour, and Notion credits don't.
      The menu bar icon is unchanged.
- [x] When the pinned window has no countdown, such as credits or an idle Notion 6-hour,
      Overview takes `resets in …` from the soonest sibling window or the plan renewal.
- [x] **Cursor on-demand.** When enabled, a third window plus `On-demand: $0 / $10`,
      in cents from `individualUsage.onDemand`. Pinned statically in Settings.
- [x] Banner clicks stay on one Respawken. Notification Center used to `open` the
      `/Applications` copy as a second instance. A click now opens the panel.
      `./build.sh --install` is the daily driver for banners and login. `--run` stays on
      `dist/` for iterating.
- [x] **Panel keyboard.** ↑/↓ move the highlight across Overview rows, back, gear,
      refresh, and Quit. Enter activates. Esc goes back, or closes the panel on
      Overview. Hover uses the same highlight.
- [x] **Menu bar icon style.** Settings → Menu bar icon picks Meters (default), Status
      (solid severity pills, no fill), or App Icon (a monotone template ring that dims
      clockwise as the fullest pinned window fills). `--preview` writes all three at 2×.

## Known gaps

- Early in a window, it can say "on pace" while ahead of expected usage, because the
  forecast thresholds don't allow an exhaustion estimate yet.
- Claude shows no account email. The usage endpoint doesn't return one, unlike Codex and
  Cursor. Claude rows use the configured labels, Personal and Work.
- Claude's Opus, Sonnet, and Cowork weekly windows are still `null` on Team. Fable is the
  scoped weekly that does arrive, via `limits[]` rather than a `seven_day_*` key.
- Settings can't reorder accounts yet. They appear in list order. Add and remove work.
- Notion AI uses undocumented `app.notion.com/api/v3` endpoints with the desktop session
  cookie, and Notion can change them without notice. Accounts with several workspaces use
  the first Business or Enterprise space Notion returns.
- Antigravity reads Cloud Code `v1internal` and `agy`'s local Connect-RPC. Google can change
  either without notice. Neither exposes a renewal date.
- Cursor Other Models is a separate included pool (labs, open weights), not a tier after
  Cursor Models. On-demand is the fallback for both. Pick the pinned window in Settings.

## Not done yet

- [ ] Remember the last good reading across restarts, so the panel isn't empty on launch
- [ ] Reorder Claude accounts in Settings, by drag or up/down buttons
- [ ] Make Overview a bit more compact
- [ ] Settle the menu bar icon style after a few days of use: keep one, or keep the picker
- [ ] Show Claude's Opus, Sonnet, and Cowork weekly windows on the product screen once
      they actually arrive
