# TODO

## Working

- [x] Reuse unchanged menu bar images; fetch Notion allowance and credits concurrently.
      Polling frequency stays unchanged; memory and energy gains are not measured.
- [x] Codex log fallback reads stay bounded during appends and tolerate split UTF-8 characters.
- [x] Panel PNG exports hide the invisible AppKit opening watcher, removing the renderer's
      warning overlay.
- [x] Menu bar item showing stacked meters, no Dock icon
- [x] Dropdown panel with per-window usage, plan, and reset countdown
- [x] **Overview + product drill-down** — panel opens on one meter per icon slot
      (the window that drives the menu bar); click a row for that product's full
      windows. Claude stacks every account on one product page. Reopens on Overview.
      Hover highlights Overview rows. Tabs were tried and dropped.
- [x] **Codex** — live usage, plan, 5-hour session + weekly windows, reset countdown;
      banked reset credits from `rate_limit_reset_credits` when `available_count` > 0
- [x] **Codex** — offline fallback to the newest session log (`sessions` or
      `archived_sessions`) when the API is unreachable
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
- [x] Native Notification Center alerts at ≥98% usage, when a long window is on
      track to empty before reset, and when a window's reset time fires
- [x] **Claude accounts settings** — gear opens a Settings window; add / rename / remove
      accounts with label + config dir; persisted to Application Support; panel and
      menu bar rebuild from that list. Codex and Cursor stay single-source.
- [x] **Notion AI** — fixed 6-hour + monthly usage allowance from Notion.app session;
      Notion credits balance / monthly credits window via private `/api/v3` endpoints
- [x] **Google Antigravity** — Gemini + Claude/GPT weekly and 5-hour windows from `agy`
      OAuth (Keychain) or the running CLI's local `/usage` server
- [x] **App icon** — cooldown-ring + token core; `Resources/AppIcon.icon` (Icon Composer
      stack for macOS 26) + legacy `Assets.xcassets`; `build.sh` compiles `Assets.car` via
      `actool`, sets `CFBundleIconName`, and ships a full `.icns`. Bundle id bumped to
      `com.bjardon.respawken.app` so NC drops the blank icon cached from pre-icon builds.
      Settings → Send Test Notification (and `--test-notification`) to verify the banner icon.
- [x] Notification copy — wry titles with one emoji each + composed sentence bodies
      (`🔥 Running on fumes` / `⏳ Ahead of pace` / `✨ Fresh limits` / `👋 Still here`)
- [x] Launch at login — first launch registers via `SMAppService`; Settings toggle can undo it;
      later launches don't re-register if it was turned off
- [x] **Keyboard shortcut** — global hotkey toggles the panel (default ⌃⌥U);
      Settings → Keyboard to change or clear it. No Accessibility permission.
- [x] **Subscription renewal date** — product pages show a dedicated `Renews:` row
      for the paid plan (not the usage-window reset). Claude from
      `subscription_created_at`, Codex from the ChatGPT id-token period, Cursor
      and Notion from their billing-cycle end.
- [x] **Claude usage credits** — extra budget from `/api/oauth/usage` (`spend`,
      with legacy `extra_usage` as fallback). Meter + `$used / $limit` on the
      product page when the org has enabled it.
- [x] **Now burning** — Settings option (default for Claude and Notion) that
      follows included usage, then credits once session/weekly or 6-hour/monthly
      hits 100%. Overview reads `Now burning: <window>`. Session/6-hour stay
      pins. Cursor is not on this path.
- [x] **Burn pace** — weekly/monthly windows project cycle-average burn. One wry
      notification per cycle when ahead (`⏳ Ahead of pace`). Session, 6-hour, and
      Notion credits stay off this path. Panel callouts are parked.
- [x] Overview `resets in …` falls back to the soonest sibling window, or the plan
      renewal, when the metered window has no countdown (Now burning credits, idle
      Notion 6-hour).
- [x] **Cursor on-demand** — when enabled, a third window plus `On-demand: $0 / $10`
      (cents from `individualUsage.onDemand`). Static pick in Settings.
- [x] Banner clicks stay on one Respawken — NC used to `open` `/Applications` as a
      second instance. Click opens the panel. `./build.sh --install` is the daily
      driver (banners and login); `--run` stays on `dist/` for iterating.

## Known gaps

- Claude shows no account email — the usage endpoint doesn't return one, unlike Codex and Cursor.
  Multi-account rows use configured labels (Personal / Work) instead.
- Claude's Opus/Sonnet/Cowork weekly windows are parsed but all came back `null` on a Team plan,
  so those rows are still unproven.
- Settings has no reorder UI yet — accounts appear in list order; add/remove works.
- Notion AI uses undocumented `app.notion.com/api/v3` endpoints authenticated with the
  desktop session cookie; Notion can change them without notice. Multi-workspace accounts
  currently pick the first Business/Enterprise space Notion returns.
- Antigravity quota is Cloud Code `v1internal` plus `agy`'s local Connect-RPC; Google can
  change either without notice. No subscription renewal date is exposed.
- Cursor Now burning is parked. Other Models is a sibling included pool (labs / open
  weights), not a step after Cursor Models. On-demand is the fallback for both, and
  a linear walk would stall on unused Other Models at 0%. Pin the window in Settings.

## Not done yet

- [ ] Panel pace callouts (`below pace` / `on pace` / `empties in …`) — layout parked
- [ ] Remember the last good reading across restarts, so the panel isn't empty on launch
- [ ] Reorder Claude accounts in Settings (drag or up/down)
- [ ] Hover states on the other panel controls (back, gear, refresh, Quit)
- [ ] Make the Overview a bit more compact
- [ ] Richer product drill-downs — Claude's unproven Opus/Sonnet/Cowork weekly
      windows
