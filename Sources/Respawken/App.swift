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
            Image(nsImage: MenuBarIcon.render(store: store))
        }
        .menuBarExtraStyle(.window)

        Window("Settings", id: "settings") {
            SettingsView(store: store)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 560, height: 420)
    }
}
