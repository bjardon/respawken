# TODO

## Working

- [x] Menu bar item showing all three providers as stacked meters, no Dock icon
- [x] Dropdown panel with per-window usage, plan, and reset countdown
- [x] **Codex** — live usage, plan, weekly window, reset countdown
- [x] **Codex** — offline fallback to the last session log when the API is unreachable
- [x] **Cursor** — live usage, plan, billing-cycle reset, on-demand spend
- [x] **Claude Code** — live session and weekly windows, plan, reset countdown
- [x] An idle Claude session window reads "not started" rather than a bare 0%
- [x] Signed-out and error states that read as "no data", not "0% used"
- [x] Auto-refresh every 2 minutes + manual refresh; countdowns tick every minute
- [x] `--probe` (print live values) and `--preview` (render the UI to a PNG)
- [x] `build.sh` producing a signed `Respawken.app`

## Known gaps

- Claude shows no account email — the usage endpoint doesn't return one, unlike Codex and Cursor.
- Claude's Opus/Sonnet/Cowork weekly windows are parsed but all came back `null` on a Team plan,
  so those rows are still unproven.

## Not done yet

- [ ] Launch at login without adding it by hand in System Settings
- [ ] Notify when a limit crosses a threshold or a window resets
- [ ] Remember the last good reading across restarts, so the panel isn't empty on launch
- [ ] Stable code-signing identity so the Keychain "Always Allow" survives a rebuild
