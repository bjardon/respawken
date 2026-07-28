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
            Image(nsImage: MenuBarIcon.render(results: store.results))
        }
        .menuBarExtraStyle(.window)
    }
}
