import Foundation
import UserNotifications

/// Fires macOS Notification Center alerts when a usage window nears exhaustion or resets.
@MainActor
final class UsageNotifier {
    static let shared = UsageNotifier()

    static let exhaustionThreshold = 98.0

    private let center = UNUserNotificationCenter.current()
    private let defaults = UserDefaults.standard
    private let firedKey = "respawken.notifiedExhaustionCycles"

    private var authorized = false
    private var didRequestAuth = false

    private init() {}

    func requestAuthorizationIfNeeded() async {
        guard !didRequestAuth else { return }
        didRequestAuth = true

        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            authorized = true
        case .notDetermined:
            authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default:
            authorized = false
        }
    }

    func evaluate(results: [ProviderID: ProviderResult]) {
        guard authorized else { return }

        var currentCycles: [String: (percent: Double, provider: ProviderID, window: UsageWindow)] = [:]
        var desiredResets: [String: (date: Date, body: String)] = [:]

        for provider in ProviderID.allCases {
            guard let result = results[provider], case .ok(let snapshot) = result.outcome else {
                continue
            }
            let active = snapshot.windows.filter(\.isActive)
            for window in active {
                currentCycles[cycleKey(provider: provider, window: window)] = (window.clamped, provider, window)
            }
            collectResets(provider: provider, windows: active, into: &desiredResets)
        }

        evaluateExhaustion(currentCycles)
        syncResetNotifications(desired: desiredResets)
    }

    // MARK: - Exhaustion

    private func evaluateExhaustion(
        _ currentCycles: [String: (percent: Double, provider: ProviderID, window: UsageWindow)]
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
                body: "\(entry.provider.title) · \(entry.window.title) at \(Format.percent(entry.percent))"
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
        windows: [UsageWindow],
        into desired: inout [String: (date: Date, body: String)]
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
            desired["reset.\(provider.rawValue).shared"] = (first, "\(provider.title) limits reset")
            return
        }

        for (window, date) in withReset {
            desired["reset.\(provider.rawValue).\(window.id)"] = (
                date,
                "\(provider.title) · \(window.title) reset"
            )
        }
    }

    private func syncResetNotifications(desired: [String: (date: Date, body: String)]) {
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
                   existing?.content.body == entry.body {
                    continue
                }
                scheduleReset(id: id, date: entry.date, body: entry.body)
            }
        }
    }

    private func scheduleReset(id: String, date: Date, body: String) {
        let content = UNMutableNotificationContent()
        content.title = "respawken"
        content.body = body
        content.sound = .default

        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    private func deliver(id: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = "respawken"
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
