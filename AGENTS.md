# Agent Guidance

Respawken is a Personal Experiment: a tiny macOS menu bar app in Swift/SwiftUI. Work outcome-first. The code is disposable, so take the shortest path to a working result and stop at the surface the user asked for. Ask only when something blocks the outcome or carries cost, safety, privacy, or external-system consequences.

- `README.md`: what each product reads, polling rules, and hard-won gotchas. Read it before touching a provider or polling.
- `TODO.md`: what works, known gaps, what's left. Read it before starting a feature.
- Notion [Devlog](https://app.notion.com/p/Respawken-39fd5cfe81be809aac5df3a63b65ed84), page id `39fd5cfe81be809aac5df3a63b65ed84`: durable decisions, learnings, and dead ends. Search it before retrying an approach that might have failed before.

## Names

Use these names in code, UI copy, docs, and replies. Map the user's words onto them.

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

**Pin.** Lock one window onto the icon.
**Reset.** `resets in …`, when that usage cycle starts over.
**Renew.** `Renews:`, when the subscription bills again. Not the same as a reset.

## Verify

A change is verified when you have seen it in the running app. Run `./build.sh --run` and check the menu bar. For readings, run `--probe` and compare against the product's own UI. For layout, run `--preview` and look at the PNG. The commands are in README → Run it. Running the app is the whole test plan; add a test suite only when asked.

## Guardrails

- Credentials stay on-device. Never log, commit, or paste Keychain items, OAuth tokens, Notion cookies, or `settings.json` contents.
- Ask before paid services, deployments, or other consequential external actions.
- Process lives in `README.md`, `TODO.md`, and the devlog. Add other ceremony (plans, issues, ADRs, `LANGUAGE.md`, review gates) only when asked.

## Wrap-up

Implement and verify freely. Wrap up only after the user explicitly accepts the work or asks to wrap up. Wrap-up is done when every step below holds:

1. The accepted behavior is verified in the running app.
2. `TODO.md` matches what shipped: finished items checked, partial work under Known gaps, the rest under Not done yet.
3. The work is committed, merged into `main`, and pushed, so `origin/main` contains it. In a worktree or branch, finish the merge yourself. An open pull request leaves wrap-up incomplete.
4. `./build.sh --install` has run from the merged code, so `/Applications/Respawken.app` matches `main`. Banners and login open that copy, not `dist/`.
5. The devlog has an entry for each durable decision, learning, or dead end from this work, or you checked and there were none. Routine implementation stays in Git and `TODO.md`.

If any step is blocked, report wrap-up as incomplete, name the blocker, and keep the work marked unshipped in `TODO.md` and the devlog.
