# respawken

A tiny macOS status bar app that shows how much Claude Code, Codex, and Cursor usage you have
left, and when each limit resets.

It answers two questions at a glance:

- **When do my limits reset?**
- **How much usage do I have left?**

Native Swift/SwiftUI, no Dock icon, ~22 MB resident, idle at 0% CPU.

![panel](docs/panel.png)

The menu bar icon is three stacked meters — Claude, Codex, Cursor, top to bottom. Fill is
utilization, colour is severity (green / amber / red). A provider that is signed out or failing
renders as an empty outline, so a missing reading never looks like a healthy zero.

## Run it

```sh
./build.sh --run
```

That produces `dist/Respawken.app` and launches it. Move the bundle wherever you like; to have it
start with the machine, add it under System Settings → General → Login Items.

Two extra modes are useful when something looks wrong:

```sh
./build.sh && ./dist/Respawken.app/Contents/MacOS/Respawken --probe     # print live values
./dist/Respawken.app/Contents/MacOS/Respawken --preview /tmp/panel.png  # render the UI to a PNG
```

## Where the numbers come from

Everything is read on-device from credentials the three tools already store. respawken never asks
you to log in again and stores nothing of its own.

| Provider | Source | Notes |
| --- | --- | --- |
| **Codex** | `~/.codex/auth.json` → `chatgpt.com/backend-api/wham/usage` | Falls back to the `rate_limits` block in the newest session log in `~/.codex/sessions`, so it still shows last-known values offline. |
| **Cursor** | `state.vscdb` → `cursor.com/api/usage-summary` | Reuses the bearer token Cursor.app already holds, so no browser cookie decryption. Cursor bills monthly, so "resets" is the end of the billing cycle. |
| **Claude Code** | `~/.claude/.credentials.json` or the `Claude Code-credentials` Keychain item → `api.anthropic.com/api/oauth/usage` | Requires `claude auth login`. The token needs the `user:profile` scope; inference-only tokens can't read usage. The response carries no account email. |

Providers are polled every 2 minutes, concurrently, with a 12-second timeout each. One provider
being slow or signed out never blocks the others.

### Two things worth knowing

**Cursor's state database is ~3 GB.** It's opened read-only with SQLite's `immutable=1`, which
skips locking and WAL recovery entirely. A point lookup returns in ~13 ms and never touches the
copy that Cursor itself is writing.

**Reading the Claude Keychain item prompts for your password.** That read costs several seconds
the first time a given binary asks for it; afterwards macOS caches the authorization for the life
of the process. respawken keeps that cost down by polling the item's *modification date* first
(17 ms, no authorization needed) and only reading the secret when Claude Code has actually
rewritten it — a login or a token refresh.

Click **Always Allow** on the prompt to stop it recurring. Note that the grant is bound to the
exact binary, so rebuilding the app will prompt again.

## Layout

```
Sources/Respawken/
  App.swift           MenuBarExtra entry point
  Store.swift         polling, concurrency, refresh cadence
  Model.swift         UsageWindow / ProviderSnapshot, formatting
  MenuBarIcon.swift   the three-meter status icon
  PanelView.swift     the dropdown
  Probe.swift         --probe and --preview
  Providers/          one file per provider
  Support/Sources.swift  Keychain, SQLite, JWT, HTTP, tolerant JSON accessors
```

Prior art: [CodexBar](https://github.com/steipete/CodexBar), which supports ~29 providers. This
tracks three and aims to stay boring.
