import Darwin
import SwiftUI

@main
enum RespawkenMain {
    static func main() {
        let args = CommandLine.arguments
        let isTool = args.contains("--probe")
            || args.contains("--preview")
            || args.contains("--test-notification")
        if !isTool {
            InstanceLock.claimOrExit()
        }
        RespawkenApp.main()
    }
}

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

/// Banner clicks go through Launch Services, which launches the registered bundle
/// (`/Applications/Respawken.app`) even when `dist/` is already running. Grab an
/// exclusive lock before SwiftUI can add a second menu extra.
enum InstanceLock {
    private static var fd: Int32 = -1

    static func claimOrExit() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Respawken", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("instance.lock").path
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            exit(0)
        }
        Self.fd = fd
    }
}

/// The registered copy may be an older binary that doesn't take InstanceLock.
/// When NC launches it anyway, the running copy dismisses it.
enum DuplicateLaunch {
    static func dismissOthers() {
        killOthers()
        for delay in [0.15, 0.5, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: killOthers)
        }
    }

    private static func killOthers() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let pid = ProcessInfo.processInfo.processIdentifier
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: id)
        where app.processIdentifier != pid {
            app.forceTerminate()
        }
    }
}
