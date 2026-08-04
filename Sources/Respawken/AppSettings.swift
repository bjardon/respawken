import Foundation

/// Persisted app preferences. Today: the Claude account list.
struct AppSettings: Codable, Equatable, Sendable {
    var claudeAccounts: [ClaudeAccount]

    static var `default`: AppSettings {
        AppSettings(claudeAccounts: [
            ClaudeAccount(id: "claude.personal", label: "Personal", configDir: "~/.claude"),
            ClaudeAccount(id: "claude.work", label: "Work", configDir: "~/.claude-oxp"),
        ])
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
