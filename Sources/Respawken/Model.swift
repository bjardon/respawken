import AppKit
import Foundation
import SwiftUI

/// Stable identity for a provider row / menu-bar meter / notification key.
/// Codex and Cursor are fixed; Claude slots are `claude.<id>` from settings.
struct ProviderID: Hashable, Identifiable, Codable, Sendable, RawRepresentable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    var id: String { rawValue }

    static let codex = ProviderID(rawValue: "codex")
    static let cursor = ProviderID(rawValue: "cursor")

    var accent: Color {
        switch rawValue {
        case Self.codex.rawValue:
            return Color(red: 0.30, green: 0.78, blue: 0.62)
        case Self.cursor.rawValue:
            return Color(red: 0.45, green: 0.60, blue: 0.95)
        default:
            return Color(red: 0.85, green: 0.47, blue: 0.30)
        }
    }

    func title(using accounts: [ClaudeAccount]) -> String {
        switch rawValue {
        case Self.codex.rawValue: return "Codex"
        case Self.cursor.rawValue: return "Cursor"
        default:
            if let label = accounts.first(where: { $0.id == rawValue })?.label, !label.isEmpty {
                return "Claude · \(label)"
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

    static func make(label: String = "New account", configDir: String = "~/.claude") -> ClaudeAccount {
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

    var clamped: Double { min(max(usedPercent, 0), 100) }
}

struct ProviderSnapshot {
    var plan: String?
    var account: String?
    var windows: [UsageWindow]
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
        if seconds <= 0 { return "now" }
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

    /// Turns a rolling window length into a human name: 18000s -> "5-hour".
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
