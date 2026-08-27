import AppKit
import Foundation
import SwiftUI

/// Stable identity for a provider row / menu-bar meter / notification key.
/// Codex, Cursor, Notion, and Antigravity are fixed; Claude slots are `claude.<id>` from settings.
struct ProviderID: Hashable, Identifiable, Codable, Sendable, RawRepresentable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    var id: String { rawValue }

    static let codex = ProviderID(rawValue: "codex")
    static let cursor = ProviderID(rawValue: "cursor")
    static let notion = ProviderID(rawValue: "notion")
    static let antigravity = ProviderID(rawValue: "antigravity")

    /// Built-in accent when the user hasn't set a custom colour.
    /// Claude accounts cycle a small palette so Personal / Work stay distinct.
    func defaultAccent(accounts: [ClaudeAccount]) -> Color {
        switch rawValue {
        case Self.codex.rawValue:
            return Color(red: 0.30, green: 0.78, blue: 0.62)
        case Self.cursor.rawValue:
            return Color(red: 0.45, green: 0.60, blue: 0.95)
        case Self.notion.rawValue:
            return Color(red: 0.25, green: 0.45, blue: 0.65)
        case Self.antigravity.rawValue:
            return Color(red: 0.48, green: 0.80, blue: 0.22)
        default:
            let palette: [Color] = [
                Color(red: 0.85, green: 0.47, blue: 0.30), // orange
                Color(red: 0.62, green: 0.48, blue: 0.90), // lavender
                Color(red: 0.90, green: 0.40, blue: 0.55), // rose
                Color(red: 0.95, green: 0.70, blue: 0.30), // amber
                Color(red: 0.40, green: 0.70, blue: 0.85), // sky
            ]
            let index = accounts.firstIndex(where: { $0.id == rawValue }) ?? 0
            return palette[index % palette.count]
        }
    }

    func title(using accounts: [ClaudeAccount]) -> String {
        switch rawValue {
        case Self.codex.rawValue: return "Codex"
        case Self.cursor.rawValue: return "Cursor"
        case Self.notion.rawValue: return "Notion AI"
        case Self.antigravity.rawValue: return "Antigravity"
        default:
            if let label = accounts.first(where: { $0.id == rawValue })?.label, !label.isEmpty {
                return "Claude · \(label)"
            }
            return "Claude"
        }
    }

    /// Spoken form for Notification Center prose — Claude accounts use parentheses.
    func notificationName(using accounts: [ClaudeAccount]) -> String {
        switch rawValue {
        case Self.codex.rawValue: return "Codex"
        case Self.cursor.rawValue: return "Cursor"
        case Self.notion.rawValue: return "Notion AI"
        case Self.antigravity.rawValue: return "Antigravity"
        default:
            if let label = accounts.first(where: { $0.id == rawValue })?.label, !label.isEmpty {
                return "Claude (\(label))"
            }
            return "Claude"
        }
    }
}

/// A Claude Code login isolated by `CLAUDE_CONFIG_DIR`.
struct ClaudeAccount: Identifiable, Codable, Equatable, Sendable {
    /// Stable id used as `ProviderID.rawValue` (e.g. `claude.personal`).
    let id: String
    var label: String
    /// Config directory as entered by the user (may include `~`).
    var configDir: String

    var providerID: ProviderID { ProviderID(rawValue: id) }

    /// Absolute path for credential lookup, or `nil` for the default `~/.claude`
    /// (unhashed Keychain service name).
    var resolvedConfigDir: String? {
        let trimmed = configDir.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let defaultDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .path
        if expanded == defaultDir { return nil }
        return expanded
    }

    static func make(label: String = L10n.t(.newAccount), configDir: String = "~/.claude") -> ClaudeAccount {
        ClaudeAccount(id: "claude.\(UUID().uuidString.lowercased())", label: label, configDir: configDir)
    }
}

/// A single rate-limit window, e.g. Codex's weekly window or Cursor's billing cycle.
struct UsageWindow: Identifiable {
    let id: String
    let title: String
    /// 0...100
    let usedPercent: Double
    let resetsAt: Date?
    /// False when the window exists but hasn't started — an idle Claude session window
    /// reports 0% with no reset time, which shouldn't read the same as "plenty left".
    var isActive: Bool = true
    /// Full length of this window. Needed to project burn pace; nil when unknown.
    var duration: TimeInterval? = nil

    var clamped: Double { min(max(usedPercent, 0), 100) }

    func pace(now: Date = Date()) -> BurnPace.Reading? {
        BurnPace.reading(window: self, now: now)
    }

    /// When this window hits 100% if the cycle-average burn continues.
    /// Nil unless it's a long window that's clearly ahead of a sustainable pace.
    func emptiesAt(now: Date = Date()) -> Date? {
        if case .ahead(let date) = pace(now: now) { return date }
        return nil
    }
}

/// Cycle-average projection for weekly / monthly windows.
/// Session and 5/6-hour windows are bursty by design — fumes covers those.
enum BurnPace {
    enum Reading {
        case below
        case on
        case ahead(Date)
    }

    /// Skip anything shorter than ~a week (daily, session, Notion's 6-hour).
    static let minDuration: TimeInterval = 6 * 24 * 60 * 60
    static let minUsedPercent = 15.0
    /// Fumes owns the last stretch.
    static let maxUsedPercent = 98.0
    static let minElapsedFraction = 0.10
    static let minLeadFraction = 0.05
    static let minLead: TimeInterval = 6 * 60 * 60
    /// Ignore mild overshoot (e.g. 40% used vs 35% expected).
    static let minProjectedFinal = 115.0
    static let maxProjectedForBelow = 85.0

    static func reading(window: UsageWindow, now: Date) -> Reading? {
        guard window.id != "credits",
              window.isActive,
              let duration = window.duration, duration >= minDuration,
              let resets = window.resetsAt, resets > now
        else { return nil }

        let elapsed = duration - resets.timeIntervalSince(now)
        guard elapsed > 0 else { return nil }

        let used = window.clamped
        if used >= maxUsedPercent { return nil }
        if let empty = emptiesAt(window: window, now: now) {
            return .ahead(empty)
        }
        if used <= 0 { return .below }
        let projectedFinal = used * duration / elapsed
        return projectedFinal < maxProjectedForBelow ? .below : .on
    }

    static func emptiesAt(window: UsageWindow, now: Date) -> Date? {
        guard window.isActive,
              let duration = window.duration, duration >= minDuration,
              let resets = window.resetsAt, resets > now
        else { return nil }

        let remainingTime = resets.timeIntervalSince(now)
        let elapsed = duration - remainingTime
        let used = window.clamped
        let remainingPct = 100 - used

        guard elapsed >= duration * minElapsedFraction,
              used >= minUsedPercent,
              used < maxUsedPercent,
              remainingPct > 0
        else { return nil }

        let rate = used / elapsed
        guard rate > 0 else { return nil }
        let projectedFinal = used * duration / elapsed
        guard projectedFinal >= minProjectedFinal else { return nil }
        let emptyAt = now.addingTimeInterval(remainingPct / rate)
        let lead = max(minLead, duration * minLeadFraction)
        guard resets.timeIntervalSince(emptyAt) >= lead else { return nil }
        return emptyAt
    }

    /// Window whose pace should sit on a shared reset line — the most urgent reading.
    static func headline(_ windows: [UsageWindow], now: Date) -> UsageWindow? {
        windows
            .compactMap { window -> (UsageWindow, Int, Date)? in
                switch window.pace(now: now) {
                case .ahead(let empty): return (window, 2, empty)
                case .on: return (window, 1, .distantFuture)
                case .below: return (window, 0, .distantFuture)
                case nil: return nil
                }
            }
            .max {
                if $0.1 != $1.1 { return $0.1 < $1.1 }
                return $0.2 > $1.2
            }?.0
    }
}

struct ProviderSnapshot {
    var plan: String?
    var account: String?
    var windows: [UsageWindow]
    /// Paid-plan billing date, distinct from usage-window `resetsAt`.
    var renewsAt: Date? = nil
    /// Where the numbers came from, shown in the panel footer of the row.
    var source: String
    var note: String?
}

enum ProviderOutcome {
    case ok(ProviderSnapshot)
    /// Provider is installed but not authenticated. Carries a hint on how to fix it.
    case signedOut(String)
    case failed(String, transient: Bool = false)
}

struct ProviderResult {
    let provider: ProviderID
    var outcome: ProviderOutcome
    var fetchedAt: Date

    var snapshot: ProviderSnapshot? {
        if case .ok(let s) = outcome { return s }
        return nil
    }

    var outcomeFailureMessage: String? {
        if case .failed(let reason, _) = outcome { return reason }
        return nil
    }

    var isTransientFailure: Bool {
        if case .failed(_, let transient) = outcome { return transient }
        return false
    }

    /// Highest utilization across windows, used for the menu bar summary.
    var peakPercent: Double? {
        snapshot?.windows.map(\.clamped).max()
    }

    /// Window that drives the menu bar meter (and Overview row).
    /// `nowBurning` follows included → overflow; any other pick is pinned.
    func iconWindow(preferredID: String) -> UsageWindow? {
        guard let windows = snapshot?.windows, !windows.isEmpty else { return nil }
        let id = IconWindowDefaults.resolved(preferred: preferredID, provider: provider, windows: windows)
        return windows.first(where: { $0.id == id })
            ?? windows.first(where: { $0.id == preferredID })
            ?? windows.first
    }

    /// Utilization for the window that drives the menu bar meter.
    /// Prefers `windowID`, then falls back through the remaining windows so a missing
    /// optional limit (e.g. unused Opus weekly) doesn't blank a healthy provider.
    func iconPercent(windowID: String) -> Double? {
        iconWindow(preferredID: windowID)?.clamped
    }

    /// Countdown for Overview: the metered window's reset, else the soonest sibling
    /// (or the plan renewal when that's all that's left — usage credits).
    func overviewReset(preferredID: String, now: Date = Date()) -> Date? {
        if let reset = iconWindow(preferredID: preferredID)?.resetsAt, reset > now {
            return reset
        }
        guard iconWindow(preferredID: preferredID)?.isActive != false else { return nil }
        let sibling = snapshot?.windows.compactMap(\.resetsAt).filter { $0 > now }.min()
        if let sibling { return sibling }
        if let renews = snapshot?.renewsAt, renews > now { return renews }
        return nil
    }
}

protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    func fetch() async -> ProviderOutcome
}

enum UsageLevel {
    case calm, warm, hot

    init(percent: Double) {
        switch percent {
        case ..<60: self = .calm
        case ..<85: self = .warm
        default: self = .hot
        }
    }

    var color: Color {
        switch self {
        case .calm: return Color(red: 0.30, green: 0.78, blue: 0.47)
        case .warm: return Color(red: 0.95, green: 0.70, blue: 0.22)
        case .hot: return Color(red: 0.93, green: 0.35, blue: 0.32)
        }
    }

    var nsColor: NSColor {
        switch self {
        case .calm: return NSColor(red: 0.30, green: 0.78, blue: 0.47, alpha: 1)
        case .warm: return NSColor(red: 0.95, green: 0.70, blue: 0.22, alpha: 1)
        case .hot: return NSColor(red: 0.93, green: 0.35, blue: 0.32, alpha: 1)
        }
    }
}

enum Format {
    /// "6d 22h", "3h 04m", "12m" — deliberately coarse; this is a glanceable app.
    static func countdown(to date: Date, now: Date = Date()) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        if seconds <= 0 { return L10n.t(.now) }
        let d = seconds / 86_400
        let h = (seconds % 86_400) / 3600
        let m = (seconds % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        return "\(m)m"
    }

    static func percent(_ value: Double) -> String {
        value >= 9.95 ? "\(Int(value.rounded()))%" : String(format: "%.1f%%", value)
    }

    /// "Aug 30, 2026" — billing dashboards show a calendar day, not a clock time.
    static func billingDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.language.rawValue)
        formatter.setLocalizedDateFormatFromTemplate("yMMMd")
        return formatter.string(from: date)
    }

    /// Next future monthly anniversary of `date` in the local calendar.
    /// ChatGPT/Claude store an old period start in UTC; the Settings page shows the local day.
    static func nextMonthly(from date: Date, now: Date = Date()) -> Date {
        let calendar = Calendar.current
        var candidate = date
        for _ in 0..<36 {
            if candidate > now { return candidate }
            guard let next = calendar.date(byAdding: .month, value: 1, to: candidate) else { break }
            candidate = next
        }
        return candidate
    }

    /// Length of the billing cycle that ends at `end` (previous calendar-month anniversary).
    static func monthlyCycleLength(ending end: Date) -> TimeInterval {
        let start = Calendar.current.date(byAdding: .month, value: -1, to: end)
            ?? end.addingTimeInterval(-30 * 86_400)
        return end.timeIntervalSince(start)
    }

    /// Turns a window length into a human name: 18000s -> "5-hour".
    static func windowName(seconds: Int) -> String {
        switch seconds {
        case 604_800: return "Weekly"
        case 86_400: return "Daily"
        case 18_000: return "5-hour"
        default:
            if seconds % 604_800 == 0 { return "\(seconds / 604_800)-week" }
            if seconds % 86_400 == 0 { return "\(seconds / 86_400)-day" }
            if seconds % 3600 == 0 { return "\(seconds / 3600)-hour" }
            return "\(max(seconds / 60, 1))-min"
        }
    }
}
