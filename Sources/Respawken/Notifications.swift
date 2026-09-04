import AppKit
import Foundation
import UserNotifications

/// Fires macOS Notification Center alerts when a usage window nears exhaustion,
/// is on track to empty before reset, or resets.
@MainActor
final class UsageNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = UsageNotifier()

    static let exhaustionThreshold = 98.0

    private let center = UNUserNotificationCenter.current()
    private let defaults = UserDefaults.standard
    private let firedKey = "respawken.notifiedExhaustionCycles"
    private let paceFiredKey = "respawken.notifiedPaceCycles"

    private var authorized = false
    private var didRequestAuth = false

    private override init() {
        super.init()
        // Claim banner clicks so NC talks to this process instead of `open`ing a new one.
        // Once a delegate is set, willPresent is required or banners stop appearing.
        center.delegate = self
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        DispatchQueue.main.async {
            PanelToggle.show()
            DuplicateLaunch.dismissOthers()
        }
        completionHandler()
    }

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
        content.title = L10n.t(.notifyTestTitle)
        content.body = L10n.t(.notifyTestBody)
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
        evaluatePace(currentCycles)
        syncResetNotifications(desired: desiredResets)
    }

    // MARK: - Exhaustion

    private func evaluateExhaustion(
        _ currentCycles: [String: (percent: Double, name: String, window: UsageWindow)]
    ) {
        var fired = Set((defaults.stringArray(forKey: firedKey) ?? []).map(Self.canonicalCycleKey))

        // Stay silenced for the whole low stretch. Drop only when the window
        // vanishes or usage falls back under 90% (a real reset, not jitter).
        fired = fired.filter { key in
            guard let entry = currentCycles[key] else { return false }
            return entry.percent >= 90
        }

        for (key, entry) in currentCycles where entry.percent >= Self.exhaustionThreshold {
            guard !fired.contains(key) else { continue }
            fired.insert(key)
            deliver(
                id: "exhaust.\(key)",
                title: L10n.t(.notifyExhaustionTitle),
                body: exhaustionBody(name: entry.name, window: entry.window, percent: entry.percent)
            )
        }

        defaults.set(Array(fired), forKey: firedKey)
    }

    // MARK: - Pace

    private func evaluatePace(
        _ currentCycles: [String: (percent: Double, name: String, window: UsageWindow)]
    ) {
        var fired = Set((defaults.stringArray(forKey: paceFiredKey) ?? []).map(Self.canonicalCycleKey))

        // Stay silenced for the rest of the cycle. Drop when the window vanishes
        // or usage falls far enough that this looks like a real reset.
        fired = fired.filter { key in
            guard let entry = currentCycles[key] else { return false }
            return entry.percent >= 12
        }

        for (key, entry) in currentCycles {
            guard let empty = entry.window.emptiesAt(), !fired.contains(key) else { continue }
            fired.insert(key)
            deliver(
                id: "pace.\(key)",
                title: L10n.t(.notifyPaceTitle),
                body: paceBody(name: entry.name, window: entry.window, empty: empty)
            )
        }

        defaults.set(Array(fired), forKey: paceFiredKey)
    }

    private func cycleKey(provider: ProviderID, window: UsageWindow) -> String {
        // Provider + window only. Claude's resets_at jitters by seconds, so stamping
        // the instant made every poll look like a new cycle and re-fired "on fumes".
        "\(provider.rawValue).\(window.id)"
    }

    /// Old keys were `provider.window.epoch` / `provider.window.none`. Strip the suffix
    /// so a relaunch after this change doesn't treat them as a fresh cycle.
    private static func canonicalCycleKey(_ key: String) -> String {
        if key.hasSuffix(".none") { return String(key.dropLast(5)) }
        guard let dot = key.lastIndex(of: ".") else { return key }
        let suffix = key[key.index(after: dot)...]
        if !suffix.isEmpty, suffix.allSatisfy(\.isNumber) {
            return String(key[..<dot])
        }
        return key
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
                L10n.t(.notifyResetTitle),
                L10n.t(.notifySharedResetBody, name)
            )
            return
        }

        for (window, date) in withReset {
            desired["reset.\(provider.rawValue).\(window.id)"] = (
                date,
                L10n.t(.notifyResetTitle),
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
        let title = L10n.windowTitle(id: window.id, stored: window.title)
        return L10n.t(
            .notifyExhaustionBody,
            name,
            L10n.notificationWindowPhrase(title),
            Format.percent(percent)
        )
    }

    private func resetBody(name: String, window: UsageWindow) -> String {
        let title = L10n.windowTitle(id: window.id, stored: window.title)
        return L10n.t(.notifyResetBody, name, L10n.notificationWindowPhrase(title))
    }

    private func paceBody(name: String, window: UsageWindow, empty: Date) -> String {
        let title = L10n.windowTitle(id: window.id, stored: window.title)
        return L10n.t(
            .notifyPaceBody,
            name,
            L10n.notificationWindowPhrase(title),
            Format.countdown(to: empty)
        )
    }
}
