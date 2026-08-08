import AppKit
import Foundation
import SwiftUI

/// sRGB components persisted for a custom provider accent.
struct RGBColor: Codable, Equatable, Sendable {
    var r: Double
    var g: Double
    var b: Double

    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(_ color: Color) {
        let ns = NSColor(color)
        let rgb = ns.usingColorSpace(.sRGB) ?? ns
        r = rgb.redComponent
        g = rgb.greenComponent
        b = rgb.blueComponent
    }

    var color: Color { Color(red: r, green: g, blue: b) }
    var nsColor: NSColor { NSColor(red: r, green: g, blue: b, alpha: 1) }
}

/// Per-provider choices that drive the menu bar icon (and panel accents).
struct ProviderIconPrefs: Codable, Equatable, Sendable {
    var showOnIcon: Bool
    /// `UsageWindow.id` to meter; `nil` means the family default.
    var windowID: String?
    /// Custom accent; `nil` means the built-in default for that provider.
    var color: RGBColor?

    static let `default` = ProviderIconPrefs(showOnIcon: true, windowID: nil, color: nil)
}

/// Persisted app preferences.
struct AppSettings: Codable, Equatable, Sendable {
    var claudeAccounts: [ClaudeAccount]
    /// Keyed by `ProviderID.rawValue`. Missing keys behave as `ProviderIconPrefs.default`.
    var providerIconPrefs: [String: ProviderIconPrefs]

    static var `default`: AppSettings {
        AppSettings(
            claudeAccounts: [
                ClaudeAccount(id: "claude.personal", label: "Personal", configDir: "~/.claude"),
                ClaudeAccount(id: "claude.work", label: "Work", configDir: "~/.claude-oxp"),
            ],
            providerIconPrefs: [:]
        )
    }

    private enum CodingKeys: String, CodingKey {
        case claudeAccounts
        case providerIconPrefs
    }

    init(claudeAccounts: [ClaudeAccount], providerIconPrefs: [String: ProviderIconPrefs] = [:]) {
        self.claudeAccounts = claudeAccounts
        self.providerIconPrefs = providerIconPrefs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        claudeAccounts = try container.decode([ClaudeAccount].self, forKey: .claudeAccounts)
        providerIconPrefs = try container.decodeIfPresent([String: ProviderIconPrefs].self, forKey: .providerIconPrefs) ?? [:]
    }

    func prefs(for provider: ProviderID) -> ProviderIconPrefs {
        providerIconPrefs[provider.rawValue] ?? .default
    }

    func showOnIcon(_ provider: ProviderID) -> Bool {
        prefs(for: provider).showOnIcon
    }

    /// Window id that should drive the icon meter for this provider.
    func iconWindowID(for provider: ProviderID) -> String {
        if let explicit = prefs(for: provider).windowID, !explicit.isEmpty {
            return explicit
        }
        return IconWindowDefaults.windowID(for: provider)
    }

    mutating func setPrefs(_ prefs: ProviderIconPrefs, for provider: ProviderID) {
        providerIconPrefs[provider.rawValue] = prefs
    }

    private static var fileURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return root
            .appendingPathComponent("Respawken", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    static func load() -> AppSettings {
        let url = fileURL
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
        else {
            return .default
        }
        return decoded
    }

    func save() {
        let url = Self.fileURL
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Built-in window ids used when the user hasn't picked one.
enum IconWindowDefaults {
    static func windowID(for provider: ProviderID) -> String {
        switch provider.rawValue {
        case ProviderID.codex.rawValue: return "secondary"
        case ProviderID.cursor.rawValue: return "included"
        case ProviderID.notion.rawValue: return "rolling"
        default: return "five_hour"
        }
    }

    /// Fallback labels when live windows aren't available yet.
    static func options(for provider: ProviderID) -> [(id: String, title: String)] {
        switch provider.rawValue {
        case ProviderID.codex.rawValue:
            return [("primary", "Session"), ("secondary", "Weekly")]
        case ProviderID.cursor.rawValue:
            return [
                ("included", "Included usage"),
                ("api", "Named models"),
                ("onDemand", "On-demand"),
            ]
        case ProviderID.notion.rawValue:
            return [
                ("rolling", "Rolling"),
                ("monthly", "Monthly"),
                ("credits", "Credits"),
            ]
        default:
            return [
                ("five_hour", "Session (5-hour)"),
                ("seven_day", "Weekly"),
                ("seven_day_opus", "Weekly · Opus"),
                ("seven_day_sonnet", "Weekly · Sonnet"),
                ("seven_day_routines", "Weekly · Routines"),
                ("seven_day_cowork", "Weekly · Cowork"),
            ]
        }
    }
}
