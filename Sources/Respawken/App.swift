import SwiftUI

@main
struct RespawkenApp: App {
    @StateObject private var store = UsageStore()

    init() {
        Probe.runIfRequested()
        // Menu-bar (LSUIElement) apps don't always publish their icon to AppKit early;
        // Notification Center is happier when NSApp has it explicitly.
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApplication.shared.applicationIconImage = icon
        }
        // SMAppService needs Launch Services to know about this bundle; App.init is too early.
        DispatchQueue.main.async {
            LaunchAtLogin.applyDefaultIfNeeded()
        }
    }

    var body: some Scene {
        // Re-evaluate window titles when language changes.
        let _ = store.settings.language
        MenuBarExtra {
            PanelView(store: store)
                .task { store.start() }
        } label: {
            // Touch published fields so the label redraws when usage or icon prefs change.
            let _ = store.settings
            let _ = store.results
            let _ = store.lastRefresh
            Image(nsImage: MenuBarIcon.render(store: store))
        }
        .menuBarExtraStyle(.window)

        Window(L10n.t(.settings), id: "settings") {
            SettingsView(store: store)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 560, height: 600)
    }
}
