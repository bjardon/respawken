# Agent Guidance

This is a Personal Experiment: a tiny macOS menu-bar app (Swift/SwiftUI) built outcome-first with disposable code and minimal process.

- Purpose and how to run: `README.md`
- Build status: `TODO.md`
- Durable decisions, learnings, and dead ends: Notion [Devlog](https://app.notion.com/p/Respawken-39fd5cfe81be809aac5df3a63b65ed84) (page id `39fd5cfe81be809aac5df3a63b65ed84`)

Implement immediately from the desired outcome. Prefer the shortest path to a working result over maintainability, abstraction, or polish beneath the requested surface. Ask only when something blocks the outcome or carries meaningful cost, safety, privacy, or external-system consequences.

## Names

**Menu bar icon.** The stacked meters in the menu bar. Click it, or the shortcut, to open the panel.
**Panel.** What opens from the icon. Not Settings, and not a menu, page, or pane.
**Overview.** Where the panel opens: one meter each, same as the icon.
**Product screen.** What you get after clicking an Overview row. Claude puts every account on one screen. Not a page or tab.
**Settings.** The window behind the gear.

**Product.** Claude, Codex, Cursor, Notion, or Antigravity.
**Account.** A Claude login. Personal and Work each get their own meter; the other products have one.
**Window.** A usage cycle (session, weekly, Cursor Models, …). Not the panel, and not Settings.
**Meter.** The bar that fills up for a window.
**Row.** Say which: an Overview row, or a window row on a product screen.

**Now burning.** Show whatever you're actually using: included first, then credits.
**Pin.** Lock one window onto the icon instead.
**Reset.** `resets in …`, when that usage cycle starts over.
**Renew.** `Renews:`, when the subscription bills again. Not the same as a reset.

## Build and verify

Rebuild and relaunch with `./build.sh --run` so the menu bar reflects the change. When a reading or layout looks wrong:

```sh
./build.sh && ./dist/Respawken.app/Contents/MacOS/Respawken --probe
./dist/Respawken.app/Contents/MacOS/Respawken --preview /tmp/panel.png
```

Verify user-visible behavior in proportion to the experiment. Do not add a professional test suite unless asked.

## Guardrails

- Credentials stay on-device. Never log, commit, or paste Keychain items, OAuth tokens, Notion cookies, or `settings.json` contents.
- Ask before paid services, deployments, or other consequential external actions.
- Do not add plans, issues, ADRs, architecture docs, `LANGUAGE.md`, required review, branch protection, or other professional ceremony unless asked.

## Wrap-up

Implement and verify freely, but ship only after the user explicitly accepts the work or asks to wrap up.

- Verify the accepted user-visible behavior (`./build.sh --run`, plus `--probe` / `--preview` if the change needs it).
- Install the accepted build with `./build.sh --install` so `/Applications/Respawken.app` matches git. Banners and login open that copy, not `dist/`.
- Refresh `TODO.md` so completed, partial, and unfinished outcomes match what shipped.
- Integrate the accepted work into `main` and push it. If the environment isolated the work, finish that integration; a pull request is not a completed wrap-up.
- Consider the Notion devlog on every wrap-up, but append only durable decisions, learnings, or dead ends. Do not duplicate routine implementation already in Git history or `TODO.md`. Use Composio/Notion tooling; page id `39fd5cfe81be809aac5df3a63b65ed84`.
- If integration is blocked, report wrap-up as incomplete and name the blocker. Do not record the work as shipped.
