import AppKit
import Foundation
import UserNotifications

/// Fires macOS Notification Center alerts when a usage window nears exhaustion or resets.
@MainActor
final class UsageNotifier {
    static let shared = UsageNotifier()

    static let exhaustionThreshold = 98.0

    private enum Copy {
        static let exhaustionTitle = "🔥 Running on fumes"
        static let resetTitle = "✨ Fresh limits"
        static let testTitle = "👋 Still here"
        static let testBody = "Test notification — looking good."
    }

    private let center = UNUserNotificationCenter.current()
    private let defaults = UserDefaults.standard
    private let firedKey = "respawken.notifiedExhaustionCycles"

    private var authorized = false
    private var didRequestAuth = false

    private init() {}

    func requestAuthorizationIfNeeded() async {
        guard !didRequestAuth else { return }
        didRequestAuth = true
        authorized = await refreshAuthorization(requestIfNeeded: true)
    }

    /// Immediate sample alert — useful from Settings to confirm permission + app icon.
    @discardableResult
    func sendTest() async -> Bool {
        authorized = await refreshAuthorization(requestIfNeeded: true)
        guard authorized else { return false }
        // Ensure AppKit has the bundle icon loaded — some NC paths resolve via NSApp.
        if NSApp.applicationIconImage == nil,
           let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        let id = "test.\(UUID().uuidString)"
        let content = UNMutableNotificationContent()
        content.title = Copy.testTitle
        content.body = Copy.testBody
        content.sound = .default
        // Tiny delay so `--test-notification` can keep the process alive until delivery.
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.3, repeats: false)
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        return true
    }

    private func refreshAuthorization(requestIfNeeded: Bool) async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        case .notDetermined where requestIfNeeded:
            didRequestAuth = true
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default:
            return false
        }
    }

    func evaluate(
        results: [ProviderID: ProviderResult],
        order: [ProviderID],
        accounts: [ClaudeAccount]
    ) {
        guard authorized else { return }

        var currentCycles: [String: (percent: Double, name: String, window: UsageWindow)] = [:]
        var desiredResets: [String: (date: Date, title: String, body: String)] = [:]

        for provider in order {
            guard let result = results[provider], case .ok(let snapshot) = result.outcome else {
                continue
            }
            let name = provider.notificationName(using: accounts)
            let active = snapshot.windows.filter(\.isActive)
            for window in active {
                currentCycles[cycleKey(provider: provider, window: window)] = (window.clamped, name, window)
            }
            collectResets(provider: provider, name: name, windows: active, into: &desiredResets)
        }

        evaluateExhaustion(currentCycles)
        syncResetNotifications(desired: desiredResets)
    }

    // MARK: - Exhaustion

    private func evaluateExhaustion(
        _ currentCycles: [String: (percent: Double, name: String, window: UsageWindow)]
    ) {
        var fired = Set(defaults.stringArray(forKey: firedKey) ?? [])

        // Drop cycles that vanished, reset, or fell back under the threshold.
        fired = fired.filter { key in
            guard let entry = currentCycles[key] else { return false }
            return entry.percent >= Self.exhaustionThreshold
        }

        for (key, entry) in currentCycles where entry.percent >= Self.exhaustionThreshold {
            guard !fired.contains(key) else { continue }
            fired.insert(key)
            deliver(
                id: "exhaust.\(key)",
                title: Copy.exhaustionTitle,
                body: exhaustionBody(name: entry.name, window: entry.window, percent: entry.percent)
            )
        }

        defaults.set(Array(fired), forKey: firedKey)
    }

    private func cycleKey(provider: ProviderID, window: UsageWindow) -> String {
        let stamp = window.resetsAt.map { String(Int($0.timeIntervalSince1970)) } ?? "none"
        return "\(provider.rawValue).\(window.id).\(stamp)"
    }

    // MARK: - Reset scheduling

    private func collectResets(
        provider: ProviderID,
        name: String,
        windows: [UsageWindow],
        into desired: inout [String: (date: Date, title: String, body: String)]
    ) {
        let now = Date()
        let withReset = windows.compactMap { window -> (UsageWindow, Date)? in
            guard let date = window.resetsAt, date > now else { return nil }
            return (window, date)
        }
        guard !withReset.isEmpty else { return }

        // Same coalescing rule as the panel: one shared instant → one notification.
        if withReset.count > 1,
           let first = withReset.first?.1,
           withReset.allSatisfy({ abs($0.1.timeIntervalSince(first)) < 60 }) {
            desired["reset.\(provider.rawValue).shared"] = (
                first,
                Copy.resetTitle,
                "\(name)’s limits just reset"
            )
            return
        }

        for (window, date) in withReset {
            desired["reset.\(provider.rawValue).\(window.id)"] = (
                date,
                Copy.resetTitle,
                resetBody(name: name, window: window)
            )
        }
    }

    private func syncResetNotifications(desired: [String: (date: Date, title: String, body: String)]) {
        Task { [desired] in
            let pending = await center.pendingNotificationRequests()
            let ours = pending.filter { $0.identifier.hasPrefix("reset.") }
            let desiredIds = Set(desired.keys)
            let stale = ours.map(\.identifier).filter { !desiredIds.contains($0) }
            if !stale.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: stale)
            }

            for (id, entry) in desired {
                let existing = ours.first { $0.identifier == id }
                if let trigger = existing?.trigger as? UNCalendarNotificationTrigger,
                   let next = trigger.nextTriggerDate(),
                   abs(next.timeIntervalSince(entry.date)) < 2,
                   existing?.content.title == entry.title,
                   existing?.content.body == entry.body {
                    continue
                }
                scheduleReset(id: id, date: entry.date, title: entry.title, body: entry.body)
            }
        }
    }

    private func scheduleReset(id: String, date: Date, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    private func deliver(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // MARK: - Copy

    private func exhaustionBody(name: String, window: UsageWindow, percent: Double) -> String {
        "\(name)’s \(window.title.lowercased()) just hit \(Format.percent(percent))"
    }

    private func resetBody(name: String, window: UsageWindow) -> String {
        "\(name)’s \(window.title.lowercased()) just reset"
    }
}
