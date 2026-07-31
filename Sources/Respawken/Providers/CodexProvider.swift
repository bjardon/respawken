import Foundation

/// Codex exposes limits two ways:
///   1. `wham/usage`, authenticated with the OAuth token in `~/.codex/auth.json`. Authoritative.
///   2. The `rate_limits` block the CLI writes into its session rollout logs. Offline, but only
///      as fresh as the last Codex run.
///
/// The API is preferred; the log is used when the token is missing/expired or the network is down,
/// so the menu bar still shows something true-as-of-last-run instead of an error.
struct CodexProvider: UsageProvider {
    let id = ProviderID.codex

    private var home: URL {
        if let override = ProcessInfo.processInfo.environment["CODEX_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    func fetch() async -> ProviderOutcome {
        guard let token = accessToken() else {
            if let local = localSnapshot() { return .ok(local) }
            return .signedOut("Run `codex login`")
        }

        do {
            let json = try await HTTP.getJSON(
                "https://chatgpt.com/backend-api/wham/usage",
                headers: ["Authorization": "Bearer \(token)", "Accept": "application/json"]
            )
            return .ok(parse(json))
        } catch {
            if var local = localSnapshot() {
                local.note = "API unreachable — showing last session"
                return .ok(local)
            }
            if let failure = error as? HTTP.Failure, failure.status == 401 {
                return .signedOut("Token expired — run `codex login`")
            }
            if let failure = error as? HTTP.Failure {
                return .failed(failure.localizedDescription, transient: failure.isTransient)
            }
            return .failed(error.localizedDescription)
        }
    }

    private func accessToken() -> String? {
        let path = home.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = root.dict("tokens")?.string("access_token"),
              !token.isEmpty
        else { return nil }
        return token
    }

    // MARK: - API payload

    private func parse(_ json: [String: Any]) -> ProviderSnapshot {
        let limit = json.dict("rate_limit")
        var windows: [UsageWindow] = []

        if let primary = limit?.dict("primary_window"), let w = window(id: "primary", from: primary) {
            windows.append(w)
        }
        if let secondary = limit?.dict("secondary_window"), let w = window(id: "secondary", from: secondary) {
            windows.append(w)
        }
        for (index, extra) in (json["additional_rate_limits"] as? [[String: Any]] ?? []).enumerated() {
            if var w = window(id: "extra-\(index)", from: extra) {
                if let name = extra.string("name") ?? extra.string("limit_name") {
                    w = UsageWindow(id: w.id, title: name, usedPercent: w.usedPercent, resetsAt: w.resetsAt)
                }
                windows.append(w)
            }
        }

        var snapshot = ProviderSnapshot(
            plan: json.string("plan_type").map(planLabel),
            account: json.string("email"),
            windows: windows,
            source: "api"
        )

        if let credits = json.dict("credits"), credits["has_credits"] as? Bool == true {
            let balance = credits.string("balance") ?? "0"
            snapshot.note = "Credits: \(balance)"
        }
        return snapshot
    }

    private func window(id: String, from dict: [String: Any]) -> UsageWindow? {
        guard let used = dict.number("used_percent", "usedPercent") else { return nil }

        // The API reports seconds; the session log reports minutes.
        let seconds: Int
        if let minutes = dict.number("window_minutes") {
            seconds = Int(minutes * 60)
        } else {
            seconds = Int(dict.number("limit_window_seconds") ?? 0)
        }

        var resets = dict.date("reset_at", "resets_at")
        if resets == nil, let after = dict.number("reset_after_seconds") {
            resets = Date().addingTimeInterval(after)
        }

        return UsageWindow(
            id: id,
            title: seconds > 0 ? Format.windowName(seconds: seconds) : "Usage",
            usedPercent: used,
            resetsAt: resets
        )
    }

    private func planLabel(_ raw: String) -> String {
        switch raw.lowercased() {
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "free": return "Free"
        default: return raw.capitalized
        }
    }

    // MARK: - Local session log fallback

    private func localSnapshot() -> ProviderSnapshot? {
        guard let path = newestSessionLog(),
              let payload = lastRateLimits(in: path) else { return nil }

        var windows: [UsageWindow] = []
        if let primary = payload.dict("primary"), let w = window(id: "primary", from: primary) {
            windows.append(w)
        }
        if let secondary = payload.dict("secondary"), let w = window(id: "secondary", from: secondary) {
            windows.append(w)
        }
        guard !windows.isEmpty else { return nil }

        return ProviderSnapshot(
            plan: payload.string("plan_type").map(planLabel),
            account: nil,
            windows: windows,
            source: "local session log"
        )
    }

    private func newestSessionLog() -> String? {
        let root = home.appendingPathComponent("sessions")
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var newest: (path: String, date: Date)?
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if newest == nil || modified > newest!.date {
                newest = (url.path, modified)
            }
        }
        return newest?.path
    }

    private func lastRateLimits(in path: String) -> [String: Any]? {
        for line in FileTail.lines(of: path).reversed() {
            guard line.contains("\"rate_limits\""),
                  let data = line.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let limits = root.dict("payload")?.dict("rate_limits")
            else { continue }
            return limits
        }
        return nil
    }
}
