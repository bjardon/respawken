import SwiftUI

@main
struct RespawkenApp: App {
    @StateObject private var store = UsageStore()

    init() {
        Probe.runIfRequested()
    }

    var body: some Scene {
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

        Window("Settings", id: "settings") {
            SettingsView(store: store)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 560, height: 560)
    }
}
