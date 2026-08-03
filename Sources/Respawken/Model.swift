import AppKit
import Foundation
import SwiftUI

enum ProviderID: String, CaseIterable, Identifiable {
    case claudePersonal = "claude.personal"
    case claudeWork = "claude.work"
    case codex
    case cursor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claudePersonal: return "Claude · Personal"
        case .claudeWork: return "Claude · Work"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        }
    }

    var accent: Color {
        switch self {
        case .claudePersonal, .claudeWork:
            return Color(red: 0.85, green: 0.47, blue: 0.30)
        case .codex: return Color(red: 0.30, green: 0.78, blue: 0.62)
        case .cursor: return Color(red: 0.45, green: 0.60, blue: 0.95)
        }
    }
}

/// A Claude Code login isolated by `CLAUDE_CONFIG_DIR`.
struct ClaudeAccount: Sendable {
    let id: ProviderID
    let label: String
    /// Absolute config directory, or `nil` for the default `~/.claude` + unhashed Keychain service.
    let configDir: String?

    /// The two accounts on this machine: personal on the default path, work on `~/.claude-oxp`.
    static let configured: [ClaudeAccount] = [
        ClaudeAccount(id: .claudePersonal, label: "Personal", configDir: nil),
        ClaudeAccount(
            id: .claudeWork,
            label: "Work",
            configDir: NSString(string: "~/.claude-oxp").expandingTildeInPath
        ),
    ]
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
